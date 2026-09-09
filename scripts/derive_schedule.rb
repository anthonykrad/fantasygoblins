require 'json'

d = JSON.parse(File.read("league_matchups.json"))
sched = d["schedule"].select { |m| m["matchupPeriodId"] <= 14 }.map do |m|
  { "week" => m["matchupPeriodId"], "away" => m["away"]["teamId"], "home" => (m["home"] ? m["home"]["teamId"] : nil), "playoff" => false }
end
File.write("schedule.json", JSON.pretty_generate(sched))
puts "Wrote schedule.json — #{sched.size} games"
