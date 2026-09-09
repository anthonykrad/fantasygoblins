require 'json'

data = JSON.parse(File.read("league_roster.json"))

POS = { 0=>"QB", 1=>"QB", 2=>"RB", 3=>"WR", 4=>"TE", 5=>"K", 16=>"D/ST" }

def stat_line(s, pos, pro)
  {
    pos: pos, pro: pro,
    passAtt: (s["0"] || 0).round(1),
    passComp: (s["1"] || 0).round(1),
    passYds: (s["3"] || 0).round(1),
    passTD: (s["4"] || 0).round(2),
    passInt: (s["20"] || 0).round(2),
    rushAtt: (s["23"] || 0).round(1),
    rushYds: (s["24"] || 0).round(1),
    rushTD: (s["25"] || 0).round(2),
    targets: (s["58"] || 0).round(1),
    receptions: (s["41"] || s["53"] || 0).round(1),
    recYds: (s["42"] || 0).round(1),
    recTD: (s["43"] || 0).round(2),
    fgMade: (s["83"] || 0).round(1),
    fgAtt: (s["84"] || 0).round(1),
    patMade: (s["86"] || 0).round(1),
    patAtt: (s["87"] || 0).round(1),
    sacks: (s["99"] || 0).round(2),
    defInt: (s["95"] || 0).round(2),
    defTD: (s["94"] || 0).round(2),
    ptsAllowed: (s["120"] || 0).round(1),
    ydsAllowed: (s["127"] || 0).round(1),
  }
end

statlines_proj = {}
statlines_actual = {}

data["teams"].each do |t|
  t["roster"]["entries"].each do |e|
    p = e["playerPoolEntry"]["player"]
    name = p["fullName"]
    pos = POS[p["defaultPositionId"]]
    pro = p["proTeamId"]

    proj_stat = p["stats"].find { |s| s["statSourceId"] == 1 && s["statSplitTypeId"] == 0 && s["seasonId"] == 2026 }
    actual_stat = p["stats"].find { |s| s["statSourceId"] == 0 && s["statSplitTypeId"] == 0 && s["seasonId"] == 2026 }

    proj_line = proj_stat ? stat_line(proj_stat["stats"], pos, pro) : stat_line({}, pos, pro)
    proj_line[:totalTD] = (proj_line[:rushTD] + proj_line[:recTD]).round(2)
    statlines_proj[name] = proj_line

    actual_line = actual_stat ? stat_line(actual_stat["stats"], pos, pro) : stat_line({}, pos, pro)
    actual_line[:totalTD] = (actual_line[:rushTD] + actual_line[:recTD]).round(2)
    statlines_actual[name] = actual_line
  end
end

File.write("stat_leaders.json", JSON.pretty_generate({
  statlinesProj: statlines_proj,
  statlinesActual: statlines_actual
}))
puts "Wrote stat_leaders.json — #{statlines_proj.size} players (proj + actual statlines)"
