require 'octokit'
require 'awesome_print'
require 'yaml'
require 'byebug'
require 'csv'
require 'time_difference'
require 'working_hours'
require 'groupdate'

#Do an "export GITHUB_API=zzzz" before running
client = Octokit::Client.new(access_token: ENV['GITHUB_API'])
client.auto_paginate = true

WorkingHours::Config.working_hours = {
  :mon => {'09:00' => '17:00'},
  :tue => {'09:00' => '17:00'},
  :wed => {'09:00' => '17:00'},
  :thu => {'09:00' => '17:00'},
  :fri => {'09:00' => '17:00'},
}
WorkingHours::Config.time_zone = "Eastern Time (US & Canada)"
Groupdate.time_zone = "Eastern Time (US & Canada)"

reponame = ARGV[0]
repo = client.repo(reponame)
puts "Processing #{repo.name} (#{repo.id})..."

prs = client.pull_requests(repo.id, state: 'all')
#merged_prs = prs.select{ |pr| !pr.merged_at.nil? and pr.number > 230 }
merged_prs = prs.select{ |pr| !pr.merged_at.nil? }

data = merged_prs.map do |pr|
	raw_comments = client.review_comments(repo.id, pr.number)     	
	
   	raw_reviews = client.pull_request_reviews(repo.id,pr.number)
    first_review = raw_reviews.detect{|i| (i.user.login != "github-actions" and i.user.login != pr.user.login)}
    second_review = raw_reviews.detect{|i| (i.user.login != "github-actions" and i.user.login != pr.user.login and i.user.login != first_review&.user&.login)}
    
	puts "First review: #{first_review&.submitted_at} #{first_review&.user&.login}"
	puts "Second review: #{second_review&.submitted_at} #{second_review&.user&.login}"

    time_to_merge = pr.merged_at.nil? ? nil : TimeDifference.between(pr.created_at, pr.merged_at).in_hours
    time_to_first_review =  first_review&.submitted_at.nil? ? nil : TimeDifference.between(pr.created_at, first_review&.submitted_at).in_hours
    time_to_second_review =  second_review&.submitted_at.nil? ? nil : TimeDifference.between(pr.created_at, second_review&.submitted_at).in_hours
    
    wh_time_to_merge = pr.merged_at.nil? ? nil : (WorkingHours.working_time_between(pr.created_at, pr.merged_at) / 3600.0).round(2)
    wh_time_to_first_review =  first_review&.submitted_at.nil? ? nil : (WorkingHours.working_time_between(pr.created_at, first_review&.submitted_at) / 3600.0).round(2)
    wh_time_to_second_review =  second_review&.submitted_at.nil? ? nil : (WorkingHours.working_time_between(pr.created_at, second_review&.submitted_at) / 3600.0).round(2)

	puts "Created: #{pr.created_at.localtime}"
	puts "Merged: #{pr.merged_at.localtime}"
    puts "TTM: #{time_to_merge}"    
    puts "whTTM: #{wh_time_to_merge}"
    puts "TTFR: #{wh_time_to_first_review}"
   	puts "#{pr.number}, #{pr.user.login}, #{pr.state}, #{raw_comments.size}, #{pr.created_at}, #{first_review&.submitted_at}, #{pr.merged_at}, #{time_to_first_review}, #{time_to_merge}, #{pr.closed_at}"
   	
        {
            title: pr.title,
            number: pr.number,
            user: pr.user.login,
            state: pr.state,
            comment_count: raw_comments.size,
            
            created_at: pr.created_at.localtime,
            
            merged_at: pr.merged_at.localtime,
            merge_time_h: time_to_merge || "",
            merge_time_wh: wh_time_to_merge || "",
            
			first_review_time_h: time_to_first_review || "",
			first_review_time_wh: wh_time_to_first_review || "",
			first_review_by: first_review&.user&.login,

			second_review_time_h: time_to_second_review || "",
			second_review_time_wh: wh_time_to_second_review || "",
			second_review_by: second_review&.user&.login,
        }
end

column_names = data.first.keys
s=CSV.generate do |csv|
  csv << column_names
  data.each do |x|
    csv << x.values
  end
end
File.write("#{repo.name}.csv", s)