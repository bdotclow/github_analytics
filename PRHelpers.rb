require 'octokit'
require 'amazing_print'
require 'byebug'
require 'time_difference'
require 'working_hours'

module PRHelpers
	extend self
	
def validate_api_key_provided() 
	if ENV['GITHUB_API'].nil? then
		puts "You must specify GITHUB_API environment variable"
		exit(1)
	end
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
def get_build_info(client, repo, pr, commits) 
		# Need to get the status attached to any commit in the PR
	status = commits.map{|c| client.statuses(repo.id, c.sha)}.flatten
	status = status.sort_by{|x| x[:created_at]}

	status.each do |s|
		#puts "   #{s['created_at']} #{s['state']} (#{s['description']}) #{s['target_url']}"
	end
	
   	done_status = status.select{|s| s.state=="success" || s.state=="failure" }
	done_status.map do |s| 
 		start = status.detect{|i| i.state=="pending" && i.target_url==s.target_url}
 		elapsed = start.nil? ? 0 : TimeDifference.between(s.created_at, start.created_at).in_minutes
   			
		{
			start: start.created_at.localtime,
			end: s.created_at.localtime,
   			state: s.state,
   			elapsed: elapsed,
   			build_url: s.target_url
		}
   	end
end

def analyze_builds(client, repo, pr, commits) 
   	build_info = get_build_info(client, repo, pr, commits)
   	failed_builds = build_info.select{|s| "failure".eql?(s[:state])}.size
	successful_builds = build_info.select{|s| "success".eql?(s[:state])}
	build_time = successful_builds.sum{|s| s[:elapsed]} / successful_builds.size.to_f
	
   	sorted_builds = build_info.sort_by{|x| x[:start]}
   	#ap sorted_builds

	puts "   #{commits.size} commits: "					
	commits.each do |ct|
		puts "        #{ct.commit.committer.date.localtime} #{ct.sha}"
	end

	puts "   #{sorted_builds.size} builds: "
	sorted_builds.each do |build|
		puts "        #{build[:state]} #{build[:start]} -> #{build[:end]} #{build[:url]}"
	end
		
		# Try to find the root cause of any failures and track them					
	failures_solved_by_commit = 0
	spurious_failures = 0
	total_resolved_failures = 0	

			# Check if any commits happened between a failure and a success
	last_failure_time = nil
	sorted_builds.each_cons(2) do |e|
		#puts "   Considering: (#{e[0][:start]} #{e[0][:state]}) - (#{e[1][:start]} #{e[1][:state]})"
		
		if "failure".eql?(e[0][:state]) 
			if last_failure_time.nil? 
				last_failure_time = e[0][:start]
			
				#puts "        Failure start: #{last_failure_time}"
			end
		else 
			last_failure_time = nil
		end
						
		if !last_failure_time.nil? && "success".eql?(e[1][:state])
				# success found
			#puts "        Checking for commits between: (#{last_failure_time} - (#{e[1][:start]})"
			commit = commits.select{|c| c.commit.committer.date.localtime < e[1][:start] && c.commit.committer.date.localtime > last_failure_time}

			if commit.empty? then
				#puts "            0 commits between these builds - spurious failure found!"
				spurious_failures += 1
			else
				#puts "            #{commit.size} commits between these builds - legitimate failure"
				failures_solved_by_commit += 1
			end
		
			total_resolved_failures += 1
		end
	end 
	
	puts "   Spurious Failures: #{spurious_failures}, Failures Solved By Commit: #{failures_solved_by_commit}"
	
	{
		failed_builds: failed_builds,
		successful_builds: successful_builds.size,
		build_time: build_time,
		failures_solved_by_commit: failures_solved_by_commit,
   		spurious_failures: spurious_failures,
   		total_resolved_failures: total_resolved_failures, 
	}
end

def get_pr_stats(client, prs) 
	prs.map do |pr_summary|

		repo = pr_summary.head.repo
		pr = client.pull_request(repo.id, pr_summary.number)
		
		puts "\nPR #{pr.number} (#{repo.name}) - #{pr.title}"
		puts "    #{pr.html_url}"
		puts "    #{pr.head.ref} -> #{pr.base.ref} (default=#{pr.base.ref.eql?(pr.base.repo.default_branch)})"
		wh_time_to_merge = pr.merged_at.nil? ? nil : (WorkingHours.working_time_between(pr.created_at, pr.merged_at) / 3600.0).round(2)

		# Analyze reviews
		review_info = get_pr_review_info(client, repo, pr)
		#ap review_info

		# Analyze commits
		commits = client.pull_request_commits(repo.id, pr.number)
		commits.each do |c|
			#puts "#{c.commit.committer.date} #{c.sha}"
			
		end

   			#NB: &.< handles the case when no first review - safe navigation evaluates to nil, which is falsey
   		after_first_review = commits.select{ |c| review_info[:first_review_submitted_at] &.< c.commit.committer.date }					 
   		#puts("  Commits after first review: #{after_first_review.size}")

   		# Analyze builds
   		build_result = Hash.new(0)
   		build_result = analyze_builds(client, repo, pr, commits)
   		
   		{
            number: pr.number,

            lines_changed: pr.additions + pr.deletions,
            lines_added: pr.additions,
            lines_removed: pr.deletions,
            
            file_count: pr.changed_files,
            commit_count: commits.size,
            
            merge_time_wh: wh_time_to_merge || 0,	
			first_review_time_wh: review_info[:wh_time_to_first_review] || 0,
			second_review_time_wh: review_info[:wh_time_to_second_review] || 0,

            comment_count: pr.comments,
            review_comment_count: pr.review_comments,
            changes_requested: review_info[:changes_requested],
            commits_after_first_review: after_first_review.size,
            
            total_builds: build_result.size,
            successful_builds: build_result[:successful_builds],
            avg_successful_build_time: build_result[:build_time],
            
            failed_builds: build_result[:failed_builds],
            failed_builds_resolved_by_commits: build_result[:failures_solved_by_commit],
            failed_builds_spurious: build_result[:spurious_failures],
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
			
				# Exclude dependabot - not interested in how hard the bot works!
			is_dependabot = "dependabot[bot]".eql?(pr.user.login)
			
				# Exclude those that were closed but not merged
			is_merged = !pr.merged_at.nil?
						
			in_range && !is_dependabot
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

def percent(num, den) 
	(num * 100 / den.to_f).round(2)
end


end


