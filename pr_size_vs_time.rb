require 'octokit'
require 'amazing_print'
require 'byebug'
require 'csv'
require 'time_difference'
require 'working_hours'
require 'groupdate'

#Do an "export GITHUB_API=zzzz" before running
client = Octokit::Client.new(access_token: ENV['GITHUB_API'])
client.auto_paginate = true

WorkingHours::Config.working_hours = {
  :mon => {'08:00' => '18:00'},
  :tue => {'08:00' => '18:00'},
  :wed => {'08:00' => '18:00'},
  :thu => {'08:00' => '18:00'},
  :fri => {'08:00' => '18:00'},
}
WorkingHours::Config.time_zone = "Eastern Time (US & Canada)"
Groupdate.time_zone = "Eastern Time (US & Canada)"

reponame = ARGV[0]
repo = client.repo(reponame)
puts "Processing #{repo.name} (#{repo.id})..."

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

def get_pr_review_info(client, repo, pr) 
		
	raw_reviews = client.pull_request_reviews(repo.id,pr.number)
   	changes_requested = raw_reviews.count{|r| "CHANGES_REQUESTED".eql?(r.state)}
   	puts "  Changes requested: #{changes_requested}" 	
	   	
   	first_review = raw_reviews.detect{|i| (i.user.login != "github-actions" and i.user.login != pr.user.login)}
    time_to_first_review =  first_review&.submitted_at.nil? ? nil : TimeDifference.between(pr.created_at, first_review&.submitted_at).in_hours
    wh_time_to_first_review =  first_review&.submitted_at.nil? ? nil : (WorkingHours.working_time_between(pr.created_at, first_review&.submitted_at) / 3600.0).round(2)
	puts "  First review: #{first_review&.user&.login} #{first_review&.submitted_at&.localtime} Hours: #{time_to_first_review} WorkingHours: #{wh_time_to_first_review}"
		    	
    second_review = raw_reviews.detect{|i| (i.user.login != "github-actions" and i.user.login != pr.user.login and i.user.login != first_review&.user&.login)}
    time_to_second_review =  second_review&.submitted_at.nil? ? nil : TimeDifference.between(pr.created_at, second_review&.submitted_at).in_hours
   	wh_time_to_second_review =  second_review&.submitted_at.nil? ? nil : (WorkingHours.working_time_between(pr.created_at, second_review&.submitted_at) / 3600.0).round(2)
	puts "  Second review: #{second_review&.user&.login} #{second_review&.submitted_at&.localtime} Hours: #{time_to_second_review} WorkingHours: #{wh_time_to_second_review}"   	
	
	{ 
		changes_requested: changes_requested,
		
		first_review_submitted_at: first_review&.submitted_at,
		wh_time_to_first_review: time_to_first_review,
		wh_time_to_second_review: wh_time_to_second_review,
	}
end

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
 	completed_status_map.each { |s| puts "  Build #{s[:state]} - #{s[:elapsed]} minutes - #{s[:build_url]}"}
   	
   	{
   	 	success_build: completed_status_map.detect{|s| s[:state]="success"},
   		start_status: status.select {|s| s.state=="pending"}.last,
   		
   		completed_status_map: completed_status_map,
   	}
end

def get_pr_stats(repo, client, prs) 
	data = prs.map do |pr|
		wh_time_to_merge = pr.merged_at.nil? ? nil : (WorkingHours.working_time_between(pr.created_at, pr.merged_at) / 3600.0).round(2)

		# Analyze reviews
		review_info = get_pr_review_info(client, repo, pr)
		ap review_info

		# Analyze commits
		commits = client.pull_request_commits(repo.id, pr.number)
		commit_stats = get_pr_commit_stats(client, repo, commits)
		ap commit_stats
		
   			#NB: &.< handles the case when no first review - safe navigation evaluates to nil, which is falsey
   		after_first_review = commits.select{ |c| review_info[:first_review_submitted_at] &.< c.commit.committer.date }					 
   		puts("  Commits after first review: #{after_first_review.size}")
		
		files = client.pull_request_files(repo.id, pr.number)
		puts "#{pr.number}, #{files.size}, #{commits.size}, #{wh_time_to_merge}"
   		
   		raw_comments = client.review_comments(repo.id, pr.number)     	

   		# Analyze builds
   		build_info = get_build_info(client, repo, pr)
   		build_time = build_info[:success_build].nil? ? 0 : build_info[:success_build][:elapsed]
        failed_builds = build_info[:completed_status_map].select{|s| s[:state]=="failure"}.size,
   		
		build_please = raw_comments.detect{|i| i.body.downcase.include? "build please"}
		build_please = client.issue_comments(repo.id, pr.number).detect{|i| i.body.downcase.include? "build please"}
		build_please_date = build_please.nil? ? nil : build_please[:created_at]&.localtime
		time_to_build_please = build_please.nil? ? nil : TimeDifference.between(pr.created_at, build_please[:created_at]).in_minutes
		puts "Build please: #{build_please_date}"
		puts "First Build Please: #{time_to_build_please} min"


		
		{
            number: pr.number,

            changes: commit_stats[:changes],
            additions: commit_stats[:additions],
            deletions: commit_stats[:deletions],
            
            files: files.size,
            commits: commits.size,
            merge_time_wh: wh_time_to_merge || 0,
            			
			first_review_time_wh: review_info[:wh_time_to_first_review] || 0,
			second_review_time_wh: review_info[:wh_time_to_second_review] || 0,

            comment_count: raw_comments.size,
            num_changes_requested: review_info[:changes_requested],
            commits_after_first_review: after_first_review.size,
            
            failed_builds: failed_builds,
            successful_build_time: build_time,
        }
	end

	data
end



prs = client.pull_requests(repo.id, state: 'closed')
merged_prs = prs.select{ |pr| !pr.merged_at.nil? }
recent_prs = merged_prs.select{|pr| TimeDifference.between(Time.now, pr.created_at).in_weeks < 8}
puts "Number of PRs to analyze: #{recent_prs.size}"

data = get_pr_stats(repo, client, recent_prs)


ap data, :index => false

column_names = data.first.keys
s=CSV.generate do |csv|
  csv << column_names
  data.each do |x|
    csv << x.values
  end
end
File.write("#{repo.name}-prs.csv", s)

