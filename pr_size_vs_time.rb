require 'octokit'
require 'amazing_print'
require 'byebug'
require 'csv'
require 'time_difference'

require_relative 'PRHelpers'

MAX_DAYS_TO_ANALYZE = 7

#Do an "export GITHUB_API=zzzz" before running
client = Octokit::Client.new(access_token: ENV['GITHUB_API'])
client.auto_paginate = true

reponame = ARGV[0]
repo = client.repo(reponame)
puts "Processing #{repo.name} (#{repo.id})..."

recent_merged_prs = PRHelpers.get_recent_merged_prs(client, repo, MAX_DAYS_TO_ANALYZE)
puts "Done loading PRs: #{recent_merged_prs.size} to analyze"

data = PRHelpers.get_pr_stats(repo, client, recent_merged_prs)

#Write a CSV containing all the retrieved data
ap data, :index => false

column_names = data.first.keys
s=CSV.generate do |csv|
  csv << column_names
  data.each do |x|
    csv << x.values
  end
end
File.write("#{repo.name}-prs.csv", s)

