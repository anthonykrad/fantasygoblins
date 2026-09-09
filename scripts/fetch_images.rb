require 'json'
require 'net/http'
require 'uri'
require 'base64'

rosters = JSON.parse(File.read("all_rosters.json"))
league_raw = JSON.parse(File.read("league_roster.json"))
COOKIE = "espn_s2=#{ENV.fetch('ESPN_S2')}; SWID=#{ENV.fetch('ESPN_SWID')}"

def http_get(url, cookie: nil)
  uri = URI.parse(url)
  req = Net::HTTP::Get.new(uri)
  req["Cookie"] = cookie if cookie
  Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 15) { |http| http.request(req) }
end

# Key must match compute_model.rb's headshot_url_for() exactly, but we fetch
# via ESPN's combiner endpoint (resized) to keep the embedded page small.
def key_url_for(p)
  if p["pos"] == "D/ST"
    "https://a.espncdn.com/i/teamlogos/nfl/500/#{p["pro"].downcase}.png"
  else
    "https://a.espncdn.com/i/headshots/nfl/players/full/#{p["pid"]}.png"
  end
end

def fetch_url_for(p)
  if p["pos"] == "D/ST"
    "https://a.espncdn.com/combiner/i?img=/i/teamlogos/nfl/500/#{p["pro"].downcase}.png&w=80&h=80"
  else
    "https://a.espncdn.com/combiner/i?img=/i/headshots/nfl/players/full/#{p["pid"]}.png&w=80"
  end
end

image_map = {}
rosters.each do |p|
  key = key_url_for(p)
  next if image_map.key?(key)
  begin
    resp = http_get(fetch_url_for(p))
    if resp.code.to_i == 200
      image_map[key] = "data:image/png;base64,#{Base64.strict_encode64(resp.body)}"
    else
      STDERR.puts "headshot HTTP #{resp.code} for #{p["name"]}"
    end
  rescue => e
    STDERR.puts "headshot fetch failed for #{p["name"]}: #{e.message}"
  end
end

# Team logos, keyed by stable team id (survives renames) — separate file,
# compute_model.rb reads this as logo_map_by_id.json.
logo_map = {}
league_raw["teams"].each do |t|
  url = t["logo"]
  next unless url
  begin
    resp = http_get(url, cookie: url.include?("mystique-api") ? COOKIE : nil)
    if resp.code.to_i == 200
      ct = resp["content-type"] || "image/jpeg"
      mime = ct.include?("svg") ? "image/svg+xml" : "image/jpeg"
      logo_map[t["id"].to_s] = "data:#{mime};base64,#{Base64.strict_encode64(resp.body)}"
    else
      STDERR.puts "logo HTTP #{resp.code} for team #{t["id"]}"
    end
  rescue => e
    STDERR.puts "logo fetch failed for team #{t["id"]}: #{e.message}"
  end
end

File.write("image_map.json", JSON.generate(image_map))
File.write("logo_map_by_id.json", JSON.generate(logo_map))
puts "Wrote image_map.json (#{image_map.size} headshots) and logo_map_by_id.json (#{logo_map.size} logos)"
