model_json = File.read("model_output.json")
template = File.read(File.join(__dir__, "interactive_template.html"))
final = template.sub("__MODEL_JSON__") { model_json }
out_path = File.join(__dir__, "..", "docs", "index.html")
File.write(out_path, final)
puts "Wrote #{out_path} (#{final.bytesize} bytes)"
