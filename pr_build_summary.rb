#
# Analyze all the builds related to PRs, and dump a 
# summary of the build failures related to these builds
#


require 'octokit'
require 'amazing_print'
require 'byebug'

require_relative 'PRHelpers'

MAX_DAYS_TO_ANALYZE = 2
DAYS_OFFSET = 0

#Do an "export GITHUB_API=zzzz" before running
client = Octokit::Client.new(access_token: ENV['GITHUB_API'], per_page: 100)
client.auto_paginate = true

reponame = ARGV[0]
repo = client.repo(reponame)
puts "Processing #{repo.name} (#{repo.id})..."

	#Uncomment to pull a particular PR for testing
#pr = client.pull_request(repo.id, 1148)
#recent_merged_prs = [pr]
recent_merged_prs = PRHelpers.get_recent_merged_prs(client, repo, MAX_DAYS_TO_ANALYZE, DAYS_OFFSET)
puts "Done loading PRs: #{recent_merged_prs.size} to analyze"

data = PRHelpers.get_pr_stats(repo, client, recent_merged_prs)

pr_with_failure = data.select{ |d| d[:failed_builds] >0 }.size
total_resolved_failures = data.map{ |d| d[:failed_builds]}.sum
failures_solved_by_commit = data.map{ |d| d[:failed_builds_resolved_by_commits]}.sum
spurious_failures = data.map{ |d| d[:failed_builds_spurious]}.sum

puts "Builds summary:"
puts "\tpr_with_failure            #{pr_with_failure}"
	
puts "\ttotal_resolved_failures    #{total_resolved_failures}" 		
puts "\tfailures_solved_by_commit  #{failures_solved_by_commit}"  
puts "\tspurious_failures          #{spurious_failures}"



