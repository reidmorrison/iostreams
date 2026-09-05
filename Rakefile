require "rake/testtask"
require_relative "lib/io_streams/version"

desc "Build the iostreams gem"
task :gem do
  system "gem build iostreams.gemspec"
end

desc "Build and publish the iostreams gem, then tag and push the release"
task publish: :gem do
  system "git tag -a v#{IOStreams::VERSION} -m 'Tagging #{IOStreams::VERSION}'"
  system "git push --tags"
  system "gem push iostreams-#{IOStreams::VERSION}.gem"
  system "rm iostreams-#{IOStreams::VERSION}.gem"
end

desc "Start an IRB console with the gem loaded"
task :console do
  exec "irb -I lib -r iostreams"
end

desc "Generate docs/llms-full.txt from docs/llms.txt and the doc pages it links to"
task :llms_full do
  require "uri"

  docs_dir  = File.join(__dir__, "docs")
  llms_path = File.join(docs_dir, "llms.txt")
  out_path  = File.join(docs_dir, "llms-full.txt")

  llms_txt = File.read(llms_path)
  header   = llms_txt[/\A.*?(?=\n## Docs)/m]&.strip
  raise "Could not find intro text before '## Docs' in #{llms_path}" unless header

  docs_section = llms_txt[/^## Docs\n(.*?)(?=\n## |\z)/m, 1]
  raise "Could not find '## Docs' section in #{llms_path}" unless docs_section

  sections = docs_section.each_line.filter_map do |line|
    next unless line =~ /^- \[(?<title>[^\]]+)\]\((?<url>[^)]+)\)/

    title = $~[:title]
    path  = URI.parse($~[:url]).path.sub(%r{\A/}, "")
    path  = "index" if path.empty?
    file  = File.join(docs_dir, "#{path}.md")
    raise "Missing doc file for #{$~[:url]}: #{file}" unless File.exist?(file)

    raw = File.read(file)

    # The page heading lives in front matter, which the shared docs theme
    # renders as the page's h1. Front matter is stripped below, so lift the
    # heading back out and re-emit it. `heading` wins over `title` where a page
    # sets both, which is the same precedence the theme uses. Falls back to the
    # link text in llms.txt for a page that sets neither.
    front_matter = raw[/\A---\n(.*?)\n---\n/m, 1].to_s
    heading      = %w[heading title].
                   filter_map { |key| front_matter[/^#{key}:[ \t]*(.+)$/, 1] }.
                   first.to_s.strip.delete_prefix('"').delete_suffix('"')
    heading      = title if heading.empty?

    body = raw.sub(/\A---\n.*?\n---\n/m, "").strip
    "# #{heading}\n\n#{body}"
  end

  File.write(out_path, "#{header}\n\n#{sections.join("\n\n---\n\n")}\n")
  puts "Wrote #{out_path}"
end

Rake::TestTask.new(:test) do |t|
  t.pattern = "test/**/*_test.rb"
  t.verbose = true
  t.warning = true
end

task default: :test
