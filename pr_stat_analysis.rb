require 'octokit'
require 'amazing_print'
require 'byebug'
require 'csv'
require 'time_difference'
require 'working_hours'
require 'groupdate'

require_relative 'PRHelpers'

MAX_DAYS_TO_ANALYZE = 5

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

recent_merged_prs = PRHelpers.get_recent_merged_prs(client, repo, MAX_DAYS_TO_ANALYZE)
puts "Done loading PRs: #{recent_merged_prs.size} to analyze"

grouped = recent_merged_prs.group_by_week{|pr| pr.created_at}

data = grouped.map do |key, group|
	puts "---- #{key} (#{group.size} PRs)----"

	start = Time.now
	per_pr = PRHelpers.get_pr_stats(repo, client, group)
	
	puts "Took #{Time.now - start} seconds to process #{group.size} PRs"
	
	max_comments = per_pr.max_by {|s| s[:comment_count]}
	max_changes = per_pr.max_by {|s| s[:changes_requested]}
	
		# Early in repo history some PRs didn't have a build - exclude those from build calculation time
	pr_with_successful_builds = per_pr.select {|s| s[:successful_build_time] > 0}

	pr_with_commits_after_first_review = per_pr.select {|s| s[:commits_after_first_review] > 0}.size
	pr_with_changes_requested = per_pr.select {|s| s[:changes_requested] > 0}.size
		
	{
		week: key,
		pr_count: per_pr.size,
		
		avg_lines_changed: (per_pr.sum {|s| s[:lines_changed]} / per_pr.size.to_f).round(2),
		avg_file_count: (per_pr.sum {|s| s[:file_count]} / per_pr.size.to_f).round(2),
		
		pr_with_commits_after_first_review: pr_with_commits_after_first_review,
		percent_commits_after_first_review: (pr_with_commits_after_first_review / per_pr.size.to_f).round(2),
		
		pr_with_changes_requested: pr_with_changes_requested,
		percent_changes_requested: (pr_with_changes_requested / per_pr.size.to_f).round(2),
		
		avg_merge_time_wh: (per_pr.sum {|s| s[:merge_time_wh]} / per_pr.size).round(2),
		avg_time_to_first_review_wh: (per_pr.sum {|s| s[:first_review_time_wh]} / per_pr.size).round(2),
		avg_time_to_second_review_wh: (per_pr.sum {|s| s[:second_review_time_wh]} / per_pr.size).round(2),
		avg_successful_build_time: (pr_with_successful_builds.sum{|s| s[:successful_build_time]} / pr_with_successful_builds.size.to_f).round(2),		
		
		pr_with_build_failure: per_pr.select {|s| s[:failed_builds] > 0}.size,
		avg_comments: (per_pr.sum {|s| s[:comment_count]} / per_pr.size.to_f).round(2),
		avg_changes_requested: (per_pr.sum {|s| s[:changes_requested]} / per_pr.size.to_f).round(2),

		max_comments: max_comments[:comment_count],
		
		max_changes_requested: per_pr.max_by {|s| s[:changes_requested]}[:changes_requested],
		
		max_merge_time_wh: per_pr.max_by {|s| s[:merge_time_wh]}[:merge_time_wh],
		min_merge_time_wh: per_pr.min_by {|s| s[:merge_time_wh]}[:merge_time_wh],				
		
		max_time_to_first_review_wh: per_pr.max_by {|s| s[:first_review_time_wh]}[:first_review_time_wh],
		min_time_to_first_review_wh: per_pr.min_by {|s| s[:first_review_time_wh]}[:first_review_time_wh],
		
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