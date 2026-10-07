# The TRMNL templates (lib/trmnl/*.liquid) against what the feeds publish, with Shopify's liquid, the engine
# TRMNL renders with.
#
# Usage: trmnl_templates_test.rb <templates dir> <payloads dir>
#
# 1. Every output tag ends in `| escape`: no layer before the template escapes, and invite titles, issue titles
#    and torrent names come from strangers.
# 2. Every template renders its feed's payload (tests/feeds_test.py writes them from the real builders) in
#    strict mode: a key the template reads and the payload lacks is an error, so a renamed field fails here.
# 3. The same payloads with a hostile suffix on every string render escaped: no tag, no attribute break.
require "json"
require "liquid"
require "minitest/autorun"

TEMPLATES, PAYLOADS = ARGV.shift(2)

# template -> the payloads it renders
VIEWS = {
  "energy" => %w[energy],
  "terminal" => %w[stats],
  "calendar" => %w[calendar-week calendar-day calendar-month],
  "arxiv" => %w[arxiv],
  "github" => %w[github],
}.freeze
HOSTILE = %q{<script>x</script><img src=//t>"'&p<q}.freeze
# what may never reach the device unescaped
RAW = ["<script>", "<img", "p<q", "\"'&"].freeze
# the values the templates branch on; a suffix would only take the other branch
KEYS_KEPT = %w[view].freeze

def template_load(name)
  Liquid::Template.parse(File.read(File.join(TEMPLATES, "#{name}.liquid"), encoding: "UTF-8"), error_mode: :strict)
end

def payload_load(name)
  JSON.parse(File.read(File.join(PAYLOADS, "#{name}.json"), encoding: "UTF-8"))
end

def render(template, payload)
  out = template.render(payload, strict_variables: true, strict_filters: true)
  raise "liquid errors: #{template.errors.map(&:to_s).join("; ")}" unless template.errors.empty?
  out
end

def hostile(value, key = nil)
  case value
  when Hash then value.to_h { |k, v| [k, hostile(v, k)] }
  when Array then value.map { |v| hostile(v) }
  when String then KEYS_KEPT.include?(key) ? value : value + HOSTILE
  else value
  end
end

class Templates < Minitest::Test
  def test_every_template_has_a_payload
    assert_equal VIEWS.keys.sort, Dir.children(TEMPLATES).map { |f| File.basename(f, ".liquid") }.sort
  end

  def test_every_output_is_escaped
    VIEWS.each_key do |name|
      outputs = File.read(File.join(TEMPLATES, "#{name}.liquid"), encoding: "UTF-8").scan(/\{\{-?(.*?)-?\}\}/m).flatten
      refute_empty outputs, name
      outputs.each { |o| assert_match(/\|\s*escape\s*\z/, o.strip, "#{name}: {{#{o}}} is not escaped") }
    end
  end

  def test_payloads_render_strictly
    VIEWS.each do |name, payloads|
      payloads.each do |payload|
        out = render(template_load(name), payload_load(payload))
        refute_match(/Liquid error/i, out, "#{name} with #{payload}")
      end
    end
  end

  def test_hostile_strings_come_out_escaped
    VIEWS.each do |name, payloads|
      payloads.each do |payload|
        out = render(template_load(name), hostile(payload_load(payload)))
        assert_includes out, "&lt;script&gt;", "#{name} with #{payload}: no string reached the output"
        RAW.each { |raw| refute_includes out, raw, "#{name} with #{payload}: #{raw} unescaped" }
      end
    end
  end
end
