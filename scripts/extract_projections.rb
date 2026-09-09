require 'json'

d = JSON.parse(File.read("league_roster.json"))

POS = { 0=>"QB", 1=>"QB", 2=>"RB", 3=>"WR", 4=>"TE", 5=>"K", 16=>"D/ST" }
SLOT_BENCH = [20, 21]

projections = []
d["teams"].each do |t|
  t["roster"]["entries"].each do |e|
    p = e["playerPoolEntry"]["player"]
    stats = p["stats"] || []
    season_proj = stats.find { |s| s["seasonId"] == 2026 && s["statSourceId"] == 1 && s["statSplitTypeId"] == 0 }
    wk1_proj = stats.find { |s| s["seasonId"] == 2026 && s["statSourceId"] == 1 && s["statSplitTypeId"] == 1 }
    projections << {
      "fteam_id" => t["id"], "fteam" => t["name"], "name" => p["fullName"],
      "pos" => (POS[p["defaultPositionId"]] || p["defaultPositionId"].to_s),
      "pro" => p["proTeamId"],
      "season_proj" => season_proj ? (season_proj["appliedTotal"] || 0).round(1) : 0,
      "wk1_proj" => wk1_proj ? (wk1_proj["appliedTotal"] || 0).round(1) : 0,
      "is_starter" => !SLOT_BENCH.include?(e["lineupSlotId"]),
      "percent_owned" => (p.dig("ownership", "percentOwned") || 0).round(1)
    }
  end
end

File.write("projections.json", JSON.pretty_generate(projections))

team_summary = projections.group_by { |p| p["fteam"] }.map do |fteam, plist|
  starters = plist.select { |p| p["is_starter"] }
  { "fteam" => fteam, "starters" => starters.sum { |p| p["season_proj"] }.round(1), "roster" => plist.sum { |p| p["season_proj"] }.round(1) }
end.sort_by { |t| -t["starters"] }
File.write("team_power_summary.json", JSON.pretty_generate(team_summary))

team_summary.each_with_index { |t, i| puts "#{i+1}. #{t["fteam"]} — starters: #{t["starters"]}, roster: #{t["roster"]}" }
