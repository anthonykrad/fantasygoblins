require 'json'

rosters = JSON.parse(File.read("all_rosters.json"))
proj = JSON.parse(File.read("projections.json"))
notes = JSON.parse(File.read("notes.json"))
schedule = JSON.parse(File.read("schedule.json"))
logos = JSON.parse(File.read("logo_map_by_id.json")) # keyed by stable team id, not name — survives team renames
league_raw = JSON.parse(File.read("league_roster.json"))
headshots = JSON.parse(File.read("image_map.json"))
matchups_raw = JSON.parse(File.read("league_matchups.json"))
stat_leaders = JSON.parse(File.read("stat_leaders.json")) # live every sync, not frozen — see extract_stat_leaders.rb

def headshot_url_for(p)
  if p["pos"] == "D/ST"
    "https://a.espncdn.com/i/teamlogos/nfl/500/#{p["pro"].downcase}.png"
  else
    "https://a.espncdn.com/i/headshots/nfl/players/full/#{p["pid"]}.png"
  end
end
HEADSHOT_BY_NAME = {}
rosters.each { |p| HEADSHOT_BY_NAME[p["name"]] = headshots[headshot_url_for(p)] }

TEAM_META = {}
league_raw["teams"].each do |t|
  TEAM_META[t["id"]] = { name: t["name"], logo: t["logo"] }
end
MEMBERS = {}
league_raw["members"].each { |m| MEMBERS[m["id"]] = "#{m["firstName"]} #{m["lastName"]}" }
league_raw["teams"].each do |t|
  owner_id = (t["owners"] || []).first
  TEAM_META[t["id"]][:owner] = MEMBERS[owner_id] || "Unknown"
end

ABBR = {
  "Hampton Inn" => "HAMP", "Team Josh" => "JOSH", "Might be gay for Hurts" => "HRTS",
  "Cj" => "CJ", "2 time champ " => "CHMP", "The Saint " => "SAINT",
  "Mikeeee" => "MIKE", "Most points scored " => "TOPS", "mamba mentality. " => "MMBA",
  "Mason" => "MASN"
}
TEAM_META.each { |id, m| m[:abbr] = ABBR[m[:name]] || m[:name][0..3].upcase }

# Which real NFL week is the most recently FULLY completed one (every matchup
# in it decided, not UNDECIDED)? 0 means the season hasn't started yet.
# Computed early — both the weighting logic below and the stat-leader/player-
# profile source (projected vs. actual stats) depend on this same flag.
completed_weeks = matchups_raw["schedule"].group_by { |m| m["matchupPeriodId"] }
  .select { |wk, games| wk <= 14 && games.any? && games.all? { |m| m["winner"] != "UNDECIDED" } }
  .keys
LATEST_COMPLETED_WEEK = completed_weeks.empty? ? 0 : completed_weeks.max
SEASON_STARTED = LATEST_COMPLETED_WEEK >= 1

# ---- 1. Player adjustments (intel cards) ----
# Map tag -> [pct adjustment, reason template]. Capped to [-0.30, +0.06] combined.
TAG_ADJUST = {
  "Injury" => -0.16,
  "Aging Watch" => -0.03,
  "Depth Chart Battle" => -0.12,
  "Volume Regression Watch" => -0.10,
  "Regression Watch" => -0.10,
  "Health Watch" => -0.05,
  "New Team" => -0.04,
  "Breakout Watch" => 0.06,
  "Bounce-Back Watch" => 0.06,
  "Elite Starter" => 0.0,
  "Workhorse Lock" => 0.0,
  "Bell-Cow Lock" => 0.0,
  "WR1 Lock" => 0.0,
  "Depth Chart Secured" => 0.0,
  "Job Secured" => 0.0,
  "Healthy" => 0.0,
  "Target Hog" => 0.0,
  "Committee" => -0.08
}

def player_adjustment(tags, notes_entry)
  return { pct: 0.0, reason: "Established starter, no flags" } if tags.empty?
  raw = tags.sum { |t| TAG_ADJUST[t] || 0.0 }
  pct = raw.clamp(-0.30, 0.06)
  bullets = notes_entry["bullets"] || []
  reason = bullets.empty? ? tags.join(", ") : bullets.join(" ")
  { pct: pct.round(3), reason: reason }
end

players_by_team = Hash.new { |h, k| h[k] = [] }
all_players_out = []

proj.each do |p|
  n = notes[p["name"]] || {}
  tags = n["tags"] || []
  adj = player_adjustment(tags, n)
  adjusted = (p["season_proj"] * (1 + adj[:pct])).round(1)
  entry = {
    name: p["name"], pos: p["pos"], pro: p["pro"],
    baseline: p["season_proj"], adjusted: adjusted,
    adjPct: adj[:pct], reason: adj[:reason],
    isStarter: p["is_starter"], fteamId: p["fteam_id"],
    headshot: HEADSHOT_BY_NAME[p["name"]],
    wk1Proj: p["wk1_proj"] || 0
  }
  players_by_team[p["fteam_id"]] << entry
  all_players_out << entry
end

# ---- 2. Per-team raw metrics ----
# ESPN's season_proj is a full-season total (~17 games played). Convert every
# points figure to a WEEKLY mean so it's comparable to a single matchup score —
# the whole win-probability model below depends on these being weekly, not seasonal.
WEEKLY_DIVISOR = 17.0

raw_metrics = {}
players_by_team.each do |fteam_id, plist|
  starters = plist.select { |p| p[:isStarter] }
  bench = plist.reject { |p| p[:isStarter] }
  lineup = (starters.sum { |p| p[:adjusted] } / WEEKLY_DIVISOR).round(1)
  top3 = (plist.sort_by { |p| -p[:adjusted] }.first(3).sum { |p| p[:adjusted] } / WEEKLY_DIVISOR).round(1)
  depth = (bench.sum { |p| p[:adjusted] } / WEEKLY_DIVISOR).round(1)
  weakest_starter = starters.min_by { |p| p[:adjusted] }
  health_loss = (starters.select { |p| p[:adjPct] < 0 }.sum { |p| p[:baseline] * -p[:adjPct] } / WEEKLY_DIVISOR).round(2)
  upside = plist.count { |p| p[:adjPct] > 0 }
  # ESPN's own current-week projection for the starting lineup, raw/unadjusted —
  # this is what shows in the app itself, kept live every sync (never frozen),
  # separate from the season-derived weekly mean used by the simulation below.
  week_proj = starters.sum { |p| p[:wk1Proj] }.round(1)

  raw_metrics[fteam_id] = {
    lineup: lineup, top3: top3, depth: depth, weekProj: week_proj,
    weakestVal: weakest_starter ? (weakest_starter[:adjusted] / WEEKLY_DIVISOR).round(2) : 0,
    weakestName: weakest_starter ? weakest_starter[:name] : "-",
    healthLoss: health_loss, upside: upside
  }
end

best_weakest = raw_metrics.values.map { |m| m[:weakestVal] }.max

# ---- 3. Win-probability season simulation ----
def normal_cdf(x)
  0.5 * (1 + erf(x / Math.sqrt(2)))
end
def erf(x)
  a1,a2,a3,a4,a5 = 0.254829592,-0.284496736,1.421413741,-1.453152027,1.061405429
  p = 0.3275911
  sign = x < 0 ? -1 : 1
  x = x.abs
  t = 1.0/(1.0+p*x)
  y = 1.0 - (((((a5*t+a4)*t)+a3)*t+a2)*t+a1)*t*Math.exp(-x*x)
  sign*y
end

SIGMA = 22.0

# ---- 4. Real schedule + Monte Carlo playoff/title simulation ----
REG_WEEKS = 14
PLAYOFF_SEEDS = 5
N_SIMS = 4000

team_ids = raw_metrics.keys

def win_prob(a_lineup, b_lineup, sigma)
  gap = a_lineup - b_lineup
  normal_cdf(gap / (sigma / Math.sqrt(17)))
end

wins_tally = Hash.new(0)
playoff_tally = Hash.new(0)
title_tally = Hash.new(0)

N_SIMS.times do
  wins = Hash.new(0)
  points_for = Hash.new(0.0)
  schedule.each do |m|
    home, away = m["home"], m["away"]
    next unless home && away
    a_l = raw_metrics[home][:lineup]
    b_l = raw_metrics[away][:lineup]
    p_home = win_prob(a_l, b_l, SIGMA)
    home_score = a_l + (rand - 0.5) * SIGMA
    away_score = b_l + (rand - 0.5) * SIGMA
    if home_score > away_score
      wins[home] += 1
    else
      wins[away] += 1
    end
    points_for[home] += home_score
    points_for[away] += away_score
  end

  team_ids.each { |t| wins_tally[t] += wins[t] }

  standings = team_ids.sort_by { |t| [-wins[t], -points_for[t]] }
  seeds = standings.first(PLAYOFF_SEEDS)
  seeds.each { |t| playoff_tally[t] += 1 }

  # Simple bracket: bye for 1-seed, wildcard 4v5, semis, final
  bracket = seeds.dup
  bye = bracket.shift
  wc_a, wc_b = bracket[2], bracket[3]
  wc_winner = win_prob(raw_metrics[wc_a][:lineup], raw_metrics[wc_b][:lineup], SIGMA) > rand ? wc_a : wc_b
  semis = [bye, bracket[0], bracket[1], wc_winner]
  sf1_w = win_prob(raw_metrics[semis[0]][:lineup], raw_metrics[semis[3]][:lineup], SIGMA) > rand ? semis[0] : semis[3]
  sf2_w = win_prob(raw_metrics[semis[1]][:lineup], raw_metrics[semis[2]][:lineup], SIGMA) > rand ? semis[1] : semis[2]
  champ = win_prob(raw_metrics[sf1_w][:lineup], raw_metrics[sf2_w][:lineup], SIGMA) > rand ? sf1_w : sf2_w
  title_tally[champ] += 1
end

proj_wins = {}
team_ids.each { |t| proj_wins[t] = (wins_tally[t].to_f / N_SIMS * REG_WEEKS).round(1) }

# ---- 5. Composite power score (0-100) ----
# "Breakout upside" is a preseason-only signal — once real Week 1 results are
# in, it stops being predictive, so drop it from the weighted score (its 7%
# is redistributed proportionally across the other six) while still computing
# and displaying the metric itself for informational purposes.
BASE_WEIGHTS = { lineup: 0.28, schedule: 0.15, balance: 0.14, topEnd: 0.13, depth: 0.12, health: 0.11, upside: 0.07 }
WEIGHTS = if SEASON_STARTED
  active = BASE_WEIGHTS.reject { |k, _| k == :upside }
  total = active.values.sum
  active.transform_values { |w| (w / total).round(4) }.merge(upside: 0.0)
else
  BASE_WEIGHTS
end

# ---- 5b. Player statlines, stat leaders, and profile popups ----
# This is intentionally NOT tied to SEASON_STARTED/the standings freeze —
# that only flips once a FULL NFL week is final, which could be days after
# the first games kick off. Stat leaders and player statlines should show
# real per-player numbers (0 for anyone who hasn't played yet) the moment
# ANY actual game stats exist, regardless of whether the whole week — and
# therefore the frozen standings — has wrapped up.
STATS_LIVE = stat_leaders["statlinesActual"].values.any? do |s|
  %w[passYds rushYds recYds sacks defInt fgMade].any? { |k| (s[k] || 0) > 0 }
end
CURRENT_STATLINES = STATS_LIVE ? stat_leaders["statlinesActual"] : stat_leaders["statlinesProj"]

def top3(statlines, key, pos_filter = nil)
  pool = statlines.select { |_, s| pos_filter.nil? || pos_filter.include?(s["pos"]) }
  pool.select { |_, s| (s[key] || 0) > 0 }
      .sort_by { |_, s| -s[key] }
      .first(3)
      .map { |name, s| { name: name, pos: s["pos"], value: s[key] } }
end

STAT_LEADERS = {
  totalTD:  top3(CURRENT_STATLINES, "totalTD", ["RB", "WR", "TE", "QB"]),
  passYds:  top3(CURRENT_STATLINES, "passYds", ["QB"]),
  passTD:   top3(CURRENT_STATLINES, "passTD", ["QB"]),
  rushYds:  top3(CURRENT_STATLINES, "rushYds", ["RB", "QB", "WR"]),
  rushTD:   top3(CURRENT_STATLINES, "rushTD", ["RB", "QB", "WR"]),
  recYds:   top3(CURRENT_STATLINES, "recYds", ["WR", "TE", "RB"]),
  recTD:    top3(CURRENT_STATLINES, "recTD", ["WR", "TE", "RB"]),
  sacks:    top3(CURRENT_STATLINES, "sacks", ["D/ST"]),
  defInt:   top3(CURRENT_STATLINES, "defInt", ["D/ST"]),
}

ADJ_BY_NAME = {}
all_players_out.each { |e| ADJ_BY_NAME[e[:name]] = e }
ROSTER_BY_NAME = {}
rosters.each { |p| ROSTER_BY_NAME[p["name"]] = p }

PLAYER_PROFILES = {}
all_players_out.each do |entry|
  name = entry[:name]
  stat = CURRENT_STATLINES[name] || {}
  ros = ROSTER_BY_NAME[name]
  n = notes[name] || {}
  PLAYER_PROFILES[name] = {
    name: name,
    pos: (ros && ros["pos"]) || stat["pos"] || entry[:pos] || "-",
    pro: (ros && ros["pro"]) || entry[:pro] || "-",
    fantasyTeam: (ros && TEAM_META[ros["fteam_id"]]) ? TEAM_META[ros["fteam_id"]][:name].strip : nil,
    injuryStatus: (ros && ros["status"]) || "ACTIVE",
    headshot: HEADSHOT_BY_NAME[name],
    projPts: entry[:adjusted],
    tags: n["tags"] || [],
    bullets: n["bullets"] || [],
    stat: stat
  }
end

def zscores(vals)
  mean = vals.sum / vals.length.to_f
  variance = vals.sum { |v| (v - mean) ** 2 } / vals.length.to_f
  sd = Math.sqrt(variance)
  sd = 1.0 if sd == 0
  vals.map { |v| (v - mean) / sd }
end

metrics_raw = {
  lineup: team_ids.map { |t| raw_metrics[t][:lineup] },
  schedule: team_ids.map { |t| proj_wins[t] },
  balance: team_ids.map { |t| raw_metrics[t][:weakestVal] },
  topEnd: team_ids.map { |t| raw_metrics[t][:top3] },
  depth: team_ids.map { |t| raw_metrics[t][:depth] },
  health: team_ids.map { |t| -raw_metrics[t][:healthLoss] },
  upside: team_ids.map { |t| raw_metrics[t][:upside] }
}
z = {}
metrics_raw.each { |k, vals| z[k] = zscores(vals) }

composite_raw = team_ids.each_with_index.map do |t, i|
  score = WEIGHTS.sum { |k, w| w * z[k][i] }
  [t, score]
end.to_h

comp_min = composite_raw.values.min
comp_max = composite_raw.values.max
comp_range = (comp_max - comp_min)
comp_range = 1.0 if comp_range == 0

def ordinal_rank(vals_by_team, tid, direction = :desc)
  sorted = vals_by_team.sort_by { |_, v| direction == :desc ? -v : v }
  sorted.index { |k, _| k == tid } + 1
end

def aspect_detail(key, val)
  case key
  when :lineup then "#{val} pts/wk"
  when :schedule then "#{val} expected wins"
  when :balance then "#{(val * 100).round}% of league best (Jaguars D/ST)"
  when :topEnd then "#{val} from top 3"
  when :depth then "#{val} pts/wk"
  when :health then "−#{(-val).round(1)} pts/wk to flags"
  when :upside then "#{val} flagged players"
  end
end

teams_out = team_ids.each_with_index.map do |tid, i|
  rating = (35 + (composite_raw[tid] - comp_min) / comp_range * 60).round(1)

  metrics = {}
  metrics_raw.each do |k, vals|
    vals_by_team = team_ids.each_with_index.map { |t, j| [t, vals[j]] }.to_h
    val = vals_by_team[tid]
    rk = ordinal_rank(vals_by_team, tid, :desc)
    metrics[k] = { value: val, rank: rk, detail: aspect_detail(k, val) }
  end

  bench_pts = raw_metrics[tid][:depth]
  bench_rank = ordinal_rank(team_ids.map { |t| [t, raw_metrics[t][:depth]] }.to_h, tid, :desc)

  opp_for_team = schedule.select { |m| m["home"] == tid || m["away"] == tid }
    .group_by { |m| m["week"] }
    .map { |wk, games| g = games.first; { week: wk, opp: g["home"] == tid ? g["away"] : g["home"] } }

  week_strip = opp_for_team.map do |o|
    opp_lineup = raw_metrics[o[:opp]][:lineup]
    my_lineup = raw_metrics[tid][:lineup]
    prob = win_prob(my_lineup, opp_lineup, SIGMA)
    {
      week: o[:week],
      prob: (prob * 100).round(1),
      opp: o[:opp] ? TEAM_META[o[:opp]][:abbr] : "-",
    }
  end

  {
    id: tid,
    name: TEAM_META[tid][:name].strip,
    abbr: TEAM_META[tid][:abbr],
    owner: TEAM_META[tid][:owner],
    logo: logos[tid.to_s],
    rating: rating,
    projWins: proj_wins[tid].floor,
    projLosses: (REG_WEEKS - proj_wins[tid].floor),
    projPts: raw_metrics[tid][:lineup],
    weekProjPts: raw_metrics[tid][:weekProj],
    benchPts: bench_pts,
    benchRank: bench_rank,
    playoffOdds: (playoff_tally[tid].to_f / N_SIMS * 100).round(1),
    titleOdds: (title_tally[tid].to_f / N_SIMS * 100).round(1),
    metrics: metrics,
    z: team_ids.each_with_index.map { |t, j| [t, {}] }.to_h[tid],
    weekStrip: week_strip,
    roster: (players_by_team[tid] || []).sort_by { |p| -p[:adjusted] }
  }
end

teams_out = teams_out.sort_by { |t| -t[:rating] }

# ---- 6. Standings freeze mechanism ----
# Player-level info (tags, injuries, headshots, "This Wk Pts") updates every
# sync. Team-level competitive outputs (rating/record/odds/metrics) only ever
# recompute the sync that happens after a full NFL week's games are all final.
SCORING_FIELDS = [:rating, :projWins, :projLosses, :projPts, :benchPts, :benchRank, :playoffOdds, :titleOdds, :metrics, :z, :weekStrip]
prev_state_file = "previous_model_output.json"
if File.exist?(prev_state_file)
  prev = JSON.parse(File.read(prev_state_file))
  prev_locked_week = prev["lastRankingUpdateWeek"] || 0
  prev_teams_by_id = {}
  (prev["teams"] || []).each { |t| prev_teams_by_id[t["id"]] = t }
  if LATEST_COMPLETED_WEEK > prev_locked_week
    LAST_RANKING_UPDATE_WEEK = LATEST_COMPLETED_WEEK
    puts "Week #{LATEST_COMPLETED_WEEK} just completed — recomputing standings (new frozen baseline)."
  else
    LAST_RANKING_UPDATE_WEEK = prev_locked_week
    teams_out.each do |t|
      prev_t = prev_teams_by_id[t[:id]]
      next unless prev_t
      SCORING_FIELDS.each { |f| t[f] = prev_t[f.to_s] }
    end
    puts "No new completed week since last standings update (still week #{LATEST_COMPLETED_WEEK}) — informational refresh only, standings frozen."
  end
else
  LAST_RANKING_UPDATE_WEEK = LATEST_COMPLETED_WEEK
  puts "No previous state found — establishing initial standings baseline (week #{LATEST_COMPLETED_WEEK})."
end

teams_out = teams_out.sort_by { |t| -t[:rating] }

output = {
  weights: WEIGHTS,
  seasonStarted: SEASON_STARTED,
  statsLive: STATS_LIVE,
  lastRankingUpdateWeek: LAST_RANKING_UPDATE_WEEK,
  latestCompletedWeek: LATEST_COMPLETED_WEEK,
  playoffSeeds: 5,
  regSeasonWeeks: 14,
  teams: teams_out,
  schedule: schedule,
  statLeaders: STAT_LEADERS,
  playerProfiles: PLAYER_PROFILES
}

File.write("model_output.json", JSON.generate(output))
puts "Wrote model_output.json"
teams_out.each_with_index { |t, i| puts "#{i+1}. #{t[:name]} — rating=#{t[:rating]}, record=#{t[:projWins]}-#{t[:projLosses]}, playoff=#{t[:playoffOdds]}%, title=#{t[:titleOdds]}%" }

# Auto-rollover: this run's output becomes next sync's frozen baseline —
File.write(prev_state_file, JSON.generate(output))
puts "Rolled over previous_model_output.json for the next sync."
