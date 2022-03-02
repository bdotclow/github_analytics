require 'octokit'
require 'amazing_print'
require 'byebug'
require 'csv'
require 'time_difference'
require 'working_hours'

require_relative 'PRHelpers'

MAX_DAYS_TO_ANALYZE = 21
DAYS_OFFSET = 0

#Do an "export GITHUB_API=zzzz" before running
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
puts "Done loading PRs: #{recent_merged_prs.size} to analyze"


data = PRHelpers.get_pr_stats(client, recent_merged_prs)

#Write a CSV containing all the retrieved data
ap data, :index => false

column_names = data.first.keys
s=CSV.generate do |csv|
  csv << column_names
  data.each do |x|
    csv << x.values
  end
end
filename = reponame.nil? ? "multiple-repo-prs.csv" : "#{reponame}-prs.csv"
File.write(filename, s)

