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
merged_prs = prs.select{ |pr| !pr.merged_at.nil? }
recent_prs = merged_prs.select{|pr| TimeDifference.between(Time.now, pr.created_at).in_weeks < 4}
puts "Number of PRs to analyze: #{recent_prs.size}"

data = recent_prs.map do |pr|
	time_to_merge = pr.merged_at.nil? ? nil : TimeDifference.between(pr.created_at, pr.merged_at).in_hours
	wh_time_to_merge = pr.merged_at.nil? ? nil : (WorkingHours.working_time_between(pr.created_at, pr.merged_at) / 3600.0).round(2)
	puts "#{pr.number} (#{pr.user.login}) Created: #{pr.created_at.localtime}, Merged: #{pr.merged_at.localtime}, Merge time: #{time_to_merge}"    	    	
		
	raw_comments = client.review_comments(repo.id, pr.number)     	
	puts "  Comments: #{raw_comments.size}"

   	raw_reviews = client.pull_request_reviews(repo.id,pr.number)
   	changes_requested = raw_reviews.count{|r| "CHANGES_REQUESTED".eql?(r.state)}
   	puts "  Changes requested: #{changes_requested}" 	
    	
   	first_review = raw_reviews.detect{|i| (i.user.login != "github-actions" and i.user.login != pr.user.login)}
    time_to_first_review =  first_review&.submitted_at.nil? ? nil : TimeDifference.between(pr.created_at, first_review&.submitted_at).in_hours
    wh_time_to_first_review =  first_review&.submitted_at.nil? ? nil : (WorkingHours.working_time_between(pr.created_at, first_review&.submitted_at) / 3600.0).round(2)
	puts "  First review: #{first_review&.user&.login} #{first_review&.submitted_at&.localtime} TTM: #{time_to_first_review} TTMwh: #{wh_time_to_first_review}"
		    	
    second_review = raw_reviews.detect{|i| (i.user.login != "github-actions" and i.user.login != pr.user.login and i.user.login != first_review&.user&.login)}
    time_to_second_review =  second_review&.submitted_at.nil? ? nil : TimeDifference.between(pr.created_at, second_review&.submitted_at).in_hours
   	wh_time_to_second_review =  second_review&.submitted_at.nil? ? nil : (WorkingHours.working_time_between(pr.created_at, second_review&.submitted_at) / 3600.0).round(2)
	puts "  Second review: #{second_review&.user&.login} #{second_review&.submitted_at&.localtime} TTM: #{time_to_second_review} TTMwh: #{wh_time_to_second_review}"
   	
    {
        title: pr.title,
        number: pr.number,
        user: pr.user.login,
        state: pr.state,
        comment_count: raw_comments.size,
        changes_requested: changes_requested,
            
        created_at: pr.created_at.localtime,
            
        merged_at: pr.merged_at.localtime,
        merge_time_h: time_to_merge || 0,
        merge_time_wh: wh_time_to_merge || 0,
            
        first_review_at: first_review&.submitted_at&.localtime || "",
		first_review_time_h: time_to_first_review || 0,
		first_review_time_wh: wh_time_to_first_review || 0,
		first_review_by: first_review&.user&.login,

        second_review_at: second_review&.submitted_at&.localtime || "",
		second_review_time_h: time_to_second_review || 0,
		second_review_time_wh: wh_time_to_second_review || 0,
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