require 'octokit'
require 'amazing_print'
require 'byebug'
require 'csv'
require 'time_difference'
require 'working_hours'
require 'groupdate'

require_relative 'PRHelpers'

MAX_DAYS_TO_ANALYZE = 21
DAYS_OFFSET = 0
REPO_FILE = "repos.txt"

PRHelpers.validate_api_key_provided() 
client = Octokit::Client.new(access_token: ENV['GITHUB_API'], per_page: 100)
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
if reponame.nil? 
	puts "Reading repositorys from #{REPO_FILE}"
	repos = File.readlines(REPO_FILE, chomp: true)
else
	puts "#{reponame} was specified on command line"
	repos = [reponame]
end

specific_pr = ARGV[1]

recent_merged_prs = []
if specific_pr.nil?
	repos.each do |r|
		repo = client.repo(r)
		puts "Processing #{repo.name} (#{repo.id})..."

		recent = PRHelpers.get_recent_merged_prs(client, repo, MAX_DAYS_TO_ANALYZE, DAYS_OFFSET)
		puts "Done loading PRs: #{recent.size} to analyze"
	
		recent_merged_prs.concat recent
	end
else
	puts "PR #{specific_pr} was specified on command line"
	repo = client.repo(reponame)
	pr = client.pull_request(repo.id, specific_pr)
	recent_merged_prs = [pr]
end

grouped = recent_merged_prs.group_by_week{|pr| pr.created_at}

data = grouped.map do |key, group|
	puts "---- #{key} (#{group.size} PRs)----"

	start = Time.now
	per_pr = PRHelpers.get_pr_stats(client, group)
	
	puts "Took #{Time.now - start} seconds to process #{group.size} PRs"
	
	max_comments = per_pr.max_by {|s| s[:comment_count]}
	max_changes = per_pr.max_by {|s| s[:changes_requested]}
	
		# Early in repo history some PRs didn't have a build - exclude those from build calculation time
	pr_with_successful_builds = per_pr.select {|s| s[:successful_builds] > 0}

	pr_with_commits_after_first_review = per_pr.select {|s| s[:commits_after_first_review] > 0}.size
	pr_with_changes_requested = per_pr.select {|s| s[:changes_requested] > 0}.size
	pr_with_build_failures = per_pr.select {|s| s[:failed_builds] > 0}.size
	pr_with_spurious_failures = per_pr.select {|s| s[:failed_builds_spurious] > 0}.size

		# Total builds
	build_total = per_pr.map{|x| x[:total_builds]}.inject(0) { |sum, x| sum += x }	
	build_failures = per_pr.map{|x| x[:failed_builds]}.inject(0) { |sum, x| sum += x }
	puts "Total Failures: #{build_failures} / #{build_total}"
	build_spurious_failures = per_pr.map{|x| x[:failed_builds_spurious]}.inject(0) { |sum, x| sum += x }
	puts "Total Spurious: #{build_spurious_failures} / #{build_total}"

	{
			# The data that I want to track week by week, first
		week: key,
		pr_count: per_pr.size,
		
		pr_spurious_failures_percent: (pr_with_spurious_failures*100 / per_pr.size.to_f).round(2),
		pr_failed_build_percent: (pr_with_build_failures*100 / per_pr.size.to_f).round(2),
		pr_commits_after_first_review_percent: (pr_with_commits_after_first_review*100 / per_pr.size.to_f).round(2),
		pr_changes_requested_percent: (pr_with_changes_requested*100 / per_pr.size.to_f).round(2),
		
		builds_failure_percent: PRHelpers.percent(build_failures, build_total),
		builds_spurious_failures_percent: PRHelpers.percent(build_spurious_failures, build_total),
		
		lines_changed_median: PRHelpers.median(per_pr.map {|s| s[:lines_changed]}),
		file_count_median: PRHelpers.median(per_pr.map {|s| s[:file_count]}),
		
		merge_time_wh_median: PRHelpers.median(per_pr.map{|s| s[:merge_time_wh]}),	
		time_to_first_review_wh_median: PRHelpers.median(per_pr.map{|s| s[:first_review_time_wh]}),
		time_to_second_review_wh_median: PRHelpers.median(per_pr.map {|s| s[:second_review_time_wh]}),
		
			# The rest of the data gives more detail or ways of looking at it
		lines_changed_avg: PRHelpers.mean(per_pr.map {|s| s[:lines_changed]}),
		file_count_avg: PRHelpers.mean(per_pr.map {|s| s[:file_count]}),
		
		failed_build_pr_count: pr_with_build_failures,	
		spurious_failures_pr_count: pr_with_spurious_failures,
		commits_after_first_review_pr_count: pr_with_commits_after_first_review,
		changes_requested_pr_count: pr_with_changes_requested,
		
		build_total: build_total,
		failed_build_total_count: build_failures,
		spurious_failures_total_count: build_spurious_failures,

		merge_time_wh_avg: PRHelpers.mean(per_pr.map{|s| s[:merge_time_wh]}),
		merge_time_wh_max: per_pr.max_by {|s| s[:merge_time_wh]}[:merge_time_wh],
		merge_time_wh_min: per_pr.min_by {|s| s[:merge_time_wh]}[:merge_time_wh],				
			
		time_to_first_review_wh_avg: PRHelpers.mean(per_pr.map{|s| s[:first_review_time_wh]}),
		time_to_first_review_wh_max: per_pr.max_by {|s| s[:first_review_time_wh]}[:first_review_time_wh],
		time_to_first_review_wh_min: per_pr.min_by {|s| s[:first_review_time_wh]}[:first_review_time_wh],

		time_to_second_review_wh_avg: PRHelpers.mean(per_pr.map {|s| s[:second_review_time_wh]}),
		time_to_second_review_wh_max: per_pr.max_by {|s| s[:second_review_time_wh]}[:second_review_time_wh],
		time_to_second_review_wh_min: per_pr.min_by {|s| s[:second_review_time_wh]}[:second_review_time_wh],
		
		successful_build_time_avg: PRHelpers.mean(pr_with_successful_builds.map{|s| s[:avg_successful_build_time]}),			
		successful_build_time_median: PRHelpers.median(pr_with_successful_builds.map{|s| s[:avg_successful_build_time]}),		
		
		comments_avg: PRHelpers.mean(per_pr.map {|s| s[:comment_count]}),
		review_comments_avg: PRHelpers.mean(per_pr.map {|s| s[:review_comment_count]}),
		comments_max: max_comments[:comment_count],
		
		changes_requested_avg: PRHelpers.mean(per_pr.map {|s| s[:changes_requested]}),
		changes_requested_max: per_pr.max_by {|s| s[:changes_requested]}[:changes_requested],
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

filename = reponame.nil? ? "multiple-stats.csv" : "#{reponame}-stats.csv"
File.write(filename, s)