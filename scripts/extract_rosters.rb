require 'json'

d = JSON.parse(File.read("league_roster.json"))

POS = { 0=>"QB", 1=>"QB", 2=>"RB", 3=>"WR", 4=>"TE", 5=>"K", 16=>"D/ST" }
PROTEAM = {0=>"FA",1=>"ATL",2=>"BUF",3=>"CHI",4=>"CIN",5=>"CLE",6=>"DAL",7=>"DEN",8=>"DET",9=>"GB",10=>"TEN",11=>"IND",12=>"KC",13=>"LV",14=>"LAR",15=>"MIA",16=>"MIN",17=>"NE",18=>"NO",19=>"NYG",20=>"NYJ",21=>"PHI",22=>"ARI",23=>"PIT",24=>"LAC",25=>"SF",26=>"SEA",27=>"TB",28=>"WSH",29=>"CAR",30=>"JAX",33=>"BAL",34=>"HOU"}
SLOT_BENCH = [20, 21]
SLOT_NAME = {
  0=>"QB",2=>"RB",3=>"RB/WR",4=>"WR",5=>"WR/TE",6=>"TE",7=>"OP",16=>"D/ST",17=>"K",
  20=>"BE",21=>"IR",23=>"FLEX"
}

rosters = []
d["teams"].each do |t|
  t["roster"]["entries"].each do |e|
    p = e["playerPoolEntry"]["player"]
    rosters << {
      "fteam" => t["name"], "fteam_id" => t["id"], "pid" => p["id"], "name" => p["fullName"],
      "pos" => (POS[p["defaultPositionId"]] || p["defaultPositionId"].to_s),
      "pro" => (PROTEAM[p["proTeamId"]] || p["proTeamId"].to_s),
      "slot" => SLOT_NAME[e["lineupSlotId"]] || e["lineupSlotId"].to_s,
      "status" => p["injuryStatus"],
      "injured" => !!p["injured"]
    }
  end
end

File.write("all_rosters.json", JSON.pretty_generate(rosters))
puts "Total players: #{rosters.size}"
pro_teams = rosters.map { |p| p["pro"] }.uniq.sort
puts "Unique pro teams: #{pro_teams.join(', ')}"
non_active = rosters.select { |p| p["status"] && p["status"] != "ACTIVE" }
puts "Non-active statuses (#{non_active.size}):"
non_active.each { |p| puts "  #{p["name"]} (#{p["pos"]} #{p["pro"]}) - #{p["status"]}" }
