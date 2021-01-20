require 'octokit'
require 'amazing_print'
require 'byebug'
require 'time_difference'
require 'working_hours'

module PRHelpers
	extend self

# Stats about number of lines changed
def get_pr_commit_stats(client, repo, commits) 
	changes = 0
	stats = commits.map do |commit|
		c = client.commit(repo.id, commit.sha)
			
		{ 
			total: c.stats.total,
			additions: c.stats.additions,
			deletions: c.stats.deletions
		}
	end
	
	{
		changes: stats.sum{|h| h[:total]},
		additions: stats.sum{|h| h[:additions]},
		deletions: stats.sum{|h| h[:deletions]},
	}
end

# Info about reviews - elapsed time until reviews happened, and count of CHANGED_REQUESTED revies
def get_pr_review_info(client, repo, pr) 	
	raw_reviews = client.pull_request_reviews(repo.id,pr.number)
   	changes_requested = raw_reviews.count{|r| "CHANGES_REQUESTED".eql?(r.state)}
   	#puts "  Changes requested: #{changes_requested}" 	
	   	
   	first_review = raw_reviews.detect{|i| (i.user.login != "github-actions" and i.user.login != pr.user.login)}
    time_to_first_review =  first_review&.submitted_at.nil? ? nil : TimeDifference.between(pr.created_at, first_review&.submitted_at).in_hours
    wh_time_to_first_review =  first_review&.submitted_at.nil? ? nil : (WorkingHours.working_time_between(pr.created_at, first_review&.submitted_at) / 3600.0).round(2)
	#puts "  First review: #{first_review&.user&.login} #{first_review&.submitted_at&.localtime} Hours: #{time_to_first_review} WorkingHours: #{wh_time_to_first_review}"
		    	
    second_review = raw_reviews.detect{|i| (i.user.login != "github-actions" and i.user.login != pr.user.login and i.user.login != first_review&.user&.login)}
    time_to_second_review =  second_review&.submitted_at.nil? ? nil : TimeDifference.between(pr.created_at, second_review&.submitted_at).in_hours
   	wh_time_to_second_review =  second_review&.submitted_at.nil? ? nil : (WorkingHours.working_time_between(pr.created_at, second_review&.submitted_at) / 3600.0).round(2)
	#puts "  Second review: #{second_review&.user&.login} #{second_review&.submitted_at&.localtime} Hours: #{time_to_second_review} WorkingHours: #{wh_time_to_second_review}"   	
	
	{ 
		changes_requested: changes_requested,
		
		first_review_submitted_at: first_review&.submitted_at,
		wh_time_to_first_review: wh_time_to_first_review,
		wh_time_to_second_review: wh_time_to_second_review,
	}
end

# Track information about builds by looking at statuses
# Completed builds times determined by looking for statuses with matching target URLs
# 	that have both a pending and a success/failure
#
# Return count of completed builds and information about each
def get_build_info(client, repo, pr) 
	status = client.statuses(repo.id, pr.head.sha)
   	done_status = status.select{|s| s.state=="success" || s.state=="failure" }
	completed_status_map = done_status.map do |s| 
 		start = status.detect{|i| i.state=="pending" && i.target_url==s.target_url}
 		elapsed = start.nil? ? 0 : TimeDifference.between(s.created_at, start.created_at).in_minutes
   			
		{
   			state: s.state,
   			elapsed: elapsed,
   			build_url: s.target_url
		}
   	end
 	#completed_status_map.each { |s| puts "  Build #{s[:state]} - #{s[:elapsed]} minutes - #{s[:build_url]}"}
   	
   	{
   	 	first_successful_build: completed_status_map.detect{|s| s[:state]="success"},
   		completed_status_map: completed_status_map,
   	}
end

def get_pr_stats(repo, client, prs) 
	prs.map do |pr|
		puts "PR #{pr.number}"
		wh_time_to_merge = pr.merged_at.nil? ? nil : (WorkingHours.working_time_between(pr.created_at, pr.merged_at) / 3600.0).round(2)

		# Analyze reviews
		review_info = get_pr_review_info(client, repo, pr)
		#ap review_info

		# Analyze commits
		commits = client.pull_request_commits(repo.id, pr.number)
		commit_stats = get_pr_commit_stats(client, repo, commits)
		#ap commit_stats
		
   			#NB: &.< handles the case when no first review - safe navigation evaluates to nil, which is falsey
   		after_first_review = commits.select{ |c| review_info[:first_review_submitted_at] &.< c.commit.committer.date }					 
   		#puts("  Commits after first review: #{after_first_review.size}")
		
		files = client.pull_request_files(repo.id, pr.number)
		
   		raw_comments = client.review_comments(repo.id, pr.number)  


   		# Analyze builds
   		build_info = get_build_info(client, repo, pr)
   		build_time = build_info[:first_successful_build].nil? ? 0 : build_info[:first_successful_build][:elapsed]
   		
   		successful_builds = build_info[:completed_status_map].select{|s| s[:state]="success"}
		build_time = successful_builds.sum{|s| s[:elapsed]} / successful_builds.size.to_f
        failed_builds = build_info[:completed_status_map].select{|s| s[:state]=="failure"}.size

		{
            number: pr.number,

            lines_changed: commit_stats[:changes],
            lines_added: commit_stats[:additions],
            lines_removed: commit_stats[:deletions],
            
            file_count: files.size,
            commit_count: commits.size,
            
            merge_time_wh: wh_time_to_merge || 0,	
			first_review_time_wh: review_info[:wh_time_to_first_review] || 0,
			second_review_time_wh: review_info[:wh_time_to_second_review] || 0,

            comment_count: raw_comments.size,
            changes_requested: review_info[:changes_requested],
            commits_after_first_review: after_first_review.size,
            
            failed_builds: failed_builds,
            successful_build_time: build_time,
        }
	end
end

#
# Get the recently merged PRs that have been created less than max_days ago
# (Don't use Octokit auto-pagination so it doesn't take forever to load the PR list) 
def get_recent_merged_prs(client, repo, max_days, offset_days=0) 
	ap = client.auto_paginate
	client.auto_paginate = false
	
	prs = nil
	merged_prs = []
	puts "Finding PRs created between #{offset_days} and #{max_days+offset_days} days ago"
	loop do
		if prs.nil?
			prs = client.pull_requests(repo.id, state: 'closed')
		else
			next_rel = client.last_response.rels[:next]
			break if (next_rel.nil?)
	
			prs = client.get(next_rel.href)
		end
		
		recent_prs = prs.select do |pr|
			days_ago = TimeDifference.between(Time.now, pr.created_at).in_days
			in_range = days_ago > offset_days && days_ago < (max_days + offset_days)
			#puts "#{pr.number} - #{days_ago} - #{in_range}"
			in_range
		end
		#puts "--- #{recent_prs.size}"
		merged_prs.concat recent_prs.select{ |pr| !pr.merged_at.nil? }
		
		min_created = prs.min_by {|pr| pr.created}	
		min_created_days_ago = min_created.nil? ? 0 : TimeDifference.between(Time.now, min_created.created_at).in_days
		break if min_created_days_ago.nil? || min_created_days_ago > (max_days+offset_days)
	end
	
	#puts "PRs merged during period: #{merged_prs.map{|pr| pr.number}}"
	client.auto_paginate = true
	merged_prs
end

def mean(array)
  (array.inject(0) { |sum, x| sum += x } / array.size.to_f).round(2)
end

# If the array has an odd number, then simply pick the one in the middle
# If the array size is even, then we must calculate the mean of the two middle.
def median(array, already_sorted=false)
  return nil if array.empty?
  array = array.sort unless already_sorted
  m_pos = array.size / 2
  return array.size % 2 == 1 ? array[m_pos] : mean(array[m_pos-1..m_pos])
end

end


