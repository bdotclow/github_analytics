require 'octokit'
require 'amazing_print'
require 'byebug'
require 'csv'
require 'time_difference'
require 'working_hours'
require 'groupdate'

require_relative 'PRHelpers'

MAX_WEEKS_TO_ANALYZE = 1

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

recent_merged_prs = PRHelpers.get_recent_merged_prs(client, repo, MAX_WEEKS_TO_ANALYZE)
puts "Done loading PRs: #{recent_merged_prs.size} to analyze"

grouped = recent_merged_prs.group_by_week{|pr| pr.created_at}

data = grouped.map do |key, group|
	puts "---- #{key} ----"

	per_pr = group.map do |pr|
		time_to_merge = pr.merged_at.nil? ? nil : TimeDifference.between(pr.created_at, pr.merged_at).in_hours
		wh_time_to_merge = pr.merged_at.nil? ? nil : (WorkingHours.working_time_between(pr.created_at, pr.merged_at) / 3600.0).round(2)
		puts "#{pr.number} (#{pr.user.login}) Created: #{pr.created_at.localtime}, Merged: #{pr.merged_at.localtime}, Hours: #{time_to_merge}, WorkingHours: #{wh_time_to_merge}"   	    	
		#ap pr
		
		raw_comments = client.review_comments(repo.id, pr.number)     	
		puts "  Comments: #{raw_comments.size}"

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
   	
   		raw_commits = client.pull_request_commits(repo.id, pr.number)
   		after_first_review = raw_commits.select{ |c| first_review!=nil && c.commit.committer.date > first_review.submitted_at}
   		puts("  Commits: #{raw_commits.size} AfterFirstReview: #{after_first_review.size}")
   		
   		# Analyze builds
   		status = client.statuses(repo.id, pr.head.sha)
   		done_status = status.select{|s| s.state=="success" || s.state=="failure" }
   		status_map = done_status.map do |s| 
   			start = status.detect{|i| i.state=="pending" && i.target_url==s.target_url}
   			elapsed = start.nil? ? 0 : TimeDifference.between(s.created_at, start.created_at).in_minutes
   			
   			{
   				state: s.state,
   				elapsed: elapsed,
   				build_url: s.target_url
   			}
   		end
   		status_map.each { |s| puts "  Build #{s[:state]} - #{s[:elapsed]} minutes - #{s[:build_url]}"}
   		
   		success_build = status_map.detect{|s| s[:state]="success"}
   		build_time = success_build.nil? ? 0 : success_build[:elapsed]
   		
   		status.each{|s| puts "#{s.created_at} - #{s.state} #{s.target_url}"}
   		start_status = status.select {|s| s.state=="pending"}.last
   		puts("First build: #{start_status[:created_at].localtime}")
   		
		
		build_please = raw_comments.detect{|i| i.body.downcase.include? "build please"}
		build_please = client.issue_comments(repo.id, pr.number).detect{|i| i.body.downcase.include? "build please"}
		build_please_date = build_please.nil? ? nil : build_please[:created_at]&.localtime
		time_to_build_please = build_please.nil? ? nil : TimeDifference.between(pr.created_at, build_please[:created_at]).in_minutes
		puts "Build please: #{build_please_date}"
		puts "First Build Please: #{time_to_build_please} min"


        {
            title: pr.title,
            number: pr.number,
            user: pr.user.login,
            state: pr.state,
            comment_count: raw_comments.size,
            changes_requested: changes_requested,
            commits_after_first_review: after_first_review.size,
            failed_builds: status_map.select{|s| s[:state]=="failure"}.size,
            successful_build_time: build_time,
            
            created_at: pr.created_at.localtime,
            
            merged_at: pr.merged_at.localtime,
            merge_time_h: time_to_merge || 0,
            merge_time_wh: wh_time_to_merge || 0,
            
			first_review_time_h: time_to_first_review || 0,
			first_review_time_wh: wh_time_to_first_review || 0,
			first_review_by: first_review&.user&.login,

			second_review_time_h: time_to_second_review || 0,
			second_review_time_wh: wh_time_to_second_review || 0,
			second_review_by: second_review&.user&.login,
        }
	end
	
	max_comments = per_pr.max_by {|s| s[:comment_count]}
	max_changes = per_pr.max_by {|s| s[:changes_requested]}
	
		# Early in repo history some PRs didn't have a build - exclude those from build calculation time
	pr_with_successful_builds = per_pr.select {|s| s[:successful_build_time] > 0}
		
	{
		week: key,
		pr_count: per_pr.size,
		pr_with_commits_after_first_review: per_pr.select {|s| s[:commits_after_first_review] > 0}.size,
		pr_with_changes_requested: per_pr.select {|s| s[:changes_requested] > 0}.size,
		
		pr_with_build_failure: per_pr.select {|s| s[:failed_builds] > 0}.size,
		pr_average_build_time: (pr_with_successful_builds.sum{|s| s[:successful_build_time]} / pr_with_successful_builds.size.to_f).round(2),
		
		avg_comments: (per_pr.sum {|s| s[:comment_count]} / per_pr.size.to_f).round(2),
		avg_changes_requested: (per_pr.sum {|s| s[:changes_requested]} / per_pr.size.to_f).round(2),
		avg_merge_time_wh: per_pr.sum {|s| s[:merge_time_wh]} / per_pr.size,
		avg_time_to_first_review_wh: per_pr.sum {|s| s[:first_review_time_wh]} / per_pr.size,
		avg_time_to_second_review_wh: per_pr.sum {|s| s[:second_review_time_wh]} / per_pr.size,
		
		max_comments: max_comments[:comment_count],
		max_comments_pr: "#{max_comments[:number]} (#{max_comments[:user]})",
		
		max_changes: per_pr.max_by {|s| s[:changes_requested]}[:changes_requested],
		max_changes_pr: "#{max_changes[:number]} (#{max_changes[:user]})",
		
		avg_merge_time_h: per_pr.sum {|s| s[:merge_time_h]} / per_pr.size,
		max_merge_time_h: per_pr.max_by {|s| s[:merge_time_h]}[:merge_time_h],	
		min_merge_time_h: per_pr.min_by {|s| s[:merge_time_h]}[:merge_time_h],					
		max_merge_time_wh: per_pr.max_by {|s| s[:merge_time_wh]}[:merge_time_wh],
		min_merge_time_wh: per_pr.min_by {|s| s[:merge_time_wh]}[:merge_time_wh],				
		
		avg_time_to_first_review_h: per_pr.sum {|s| s[:merge_time_h]} / per_pr.size,
		max_time_to_first_review_h: per_pr.max_by {|s| s[:first_review_time_h]}[:first_review_time_h],
		min_time_to_first_review_h: per_pr.min_by {|s| s[:first_review_time_h]}[:first_review_time_h],
		max_time_to_first_review_wh: per_pr.max_by {|s| s[:first_review_time_wh]}[:first_review_time_wh],
		min_time_to_first_review_wh: per_pr.min_by {|s| s[:first_review_time_wh]}[:first_review_time_wh],
		
		avg_time_to_second_review_h: per_pr.sum {|s| s[:second_review_time_h]} / per_pr.size,
		max_time_to_second_review_h: per_pr.max_by {|s| s[:second_review_time_h]}[:second_review_time_h],
		min_time_to_second_review_h: per_pr.min_by {|s| s[:second_review_time_h]}[:second_review_time_h],
		max_time_to_second_review_wh: per_pr.max_by {|s| s[:second_review_time_wh]}[:second_review_time_wh],
		min_time_to_second_review_wh: per_pr.min_by {|s| s[:second_review_time_wh]}[:second_review_time_wh],
	}
end

ap data, :index => false

column_names = data.first.keys
s=CSV.generate do |csv|
  csv << column_names
  data.each do |x|
    csv << x.values
  end
end
File.write("#{repo.name}-stats.csv", s)