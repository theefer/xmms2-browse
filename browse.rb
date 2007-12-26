#!/usr/bin/ruby

require 'xmmsclient'

require './exceptions'


# Handles the rules for virtual paths.
class VirtualPaths

  def initialize(xc)
    @rules = Hash.new
    @xc = xc
  end

  def add_rule(name, path_spec)
    raise DuplicateRuleException.new(name) if @rules.key?(name)

    if path_spec.match(/^\//)
      @rules[name] = make_rule(path_spec)
    else
      # alias for an existing rule, check existence
      raise BadRefRuleException.new(name, path_spec) unless @rules.key?(path_spec)

      # alias by copying the rule
      @rules[name] = @rules[path_spec]
    end
    self
  end

  def complete_current(arg)
    arg += '*' unless arg =~ /\*$/
    begin
      ctx = match(arg)
      print_media_values(ctx.coll, ctx.curr, ctx.allfields, ctx.full?)
    rescue InvalidActionException
      fuzzy_complete_action(arg).each do |action|
        print_element(action, false)
      end
    rescue NotVirtualPathException
      # ignore silently
    end
  end

  def list_next(arg)
    # ignore trailing slash
    arg = arg[0..-2] if arg =~ /\/$/
    ctx = match(arg)
    print_media_values(ctx.coll, ctx.next, ctx.allfields, ctx.full?)
  end

  def list_entries(arg)
    ctx = match(arg)
    res = @xc.coll_query_ids(ctx.coll, ctx.allfields)
    res.wait
    res.value.each do |id|
      info = @xc.medialib_get_info(id)
      info.wait
      dict = info.value
      puts "#{dict[:tracknr]} - #{dict[:title]}"
    end
  end


  private

  def extract_path(s)
    if parse = s.match(/^\/\/(.*)/)
      return parse[1]
    else
      raise NotVirtualPathException.new("Invalid path!")
    end
  end

  def match(s)
    path = extract_path(s)
    if parse = path.match(/^([^\/]*)\/?(.*)/)
      action = match_action(parse[1])

      # parse context
      return action.parse(parse[2])
    else
      raise NotVirtualPathException.new("Invalid path!")
    end
  end

  def match_action(action)
    if @rules.key?(action)
      return @rules[action] 
    end

    raise InvalidActionException.new("Invalid action '#{action}' !")
  end

  def fuzzy_complete_action(s)
    path = extract_path(s)
    pattern = path.gsub(/\?/, ".").gsub(/\*/, ".*")

    fuzzy = Array.new
    @rules.keys.each do |k|
      fuzzy.push(k) if k.match(/^#{pattern}$/)
    end

    return fuzzy
  end

  def make_rule(spec)
    raise InvalidRuleException.new("Empty rule!") if spec.size < 2

    tokens = spec[1..-1].split('/')
    tokens.pop if !tokens.empty? and tokens[-1].empty?

    rule = Rule.new
    tokens.each do |tk|
      # extract all variables in this token
      vars = tk.scan(/\$\{(.*?)\}/).map {|e| e.first}
      rule.add_level(vars, tk)
    end

    return rule
  end

  def print_media_values(coll, path_item, fields, terminal)
    res = @xc.coll_query_info(coll, path_item.vars, fields)
    res.wait
    res.value.each do |dict|
      s = path_item.format.gsub(/\$\{(.*?)\}/) {|| dict[$1.to_sym]}
      print_element(s, terminal)
    end
  end

  def print_element(elem, terminal)
    elem += '/' unless terminal
    puts elem.gsub(' ', '\ ')
#    puts elem
  end
end


# Rule corresponding to one virtual path.
class Rule
  def initialize()
    @defs = Array.new
  end

  def add_level(variables, format)
    ritem = RuleItem.new(variables, format)
    @defs.push(ritem)
  end

  # Build a VirtualContext from applying the rule to the input.
  def parse(path)
    elems = path.split('/')

    i = 0
    vc = VirtualContext.new(@defs)
    @defs.zip(elems).map do |d, e|
      # register field order
      vc.append_allfields(d.vars)

      # not enough elems, incomplete path
      break if e.nil?

      # extract values
      vc.append_values(d.parse_values(e)) unless e.empty?

      i += 1

      # last token is multimatch, stop to complete it
      break if (i == elems.size and is_multimatch(e))
    end

#    puts (i - 1)

    vc.set_current_index(i - 1)

    return vc
  end

  private

  # token considered a multimatch if contains wildcard
  def is_multimatch(s)
    return s.match(/[*?]/)
  end
end

class RuleItem
  attr_reader :vars, :format

  def initialize(vars, format)
    @vars = vars
    @format = format
  end

  def parse_values(s)
    h = Hash.new

    pattern = format_to_pattern(format)
    match = s.match(pattern)

    unless match.nil?
      i = 1
      @vars.each do |v|
        break if match[i].nil?
        h[v] = match[i]
        i += 1
      end
    end

    return h
  end

  private

  def format_to_pattern(format)
    def opt(s)
      return "(?:#{s})?"
    end
    def subs(format)
      format.scan(/(.*?)\$\{(.*?)\}(.*)/) do |s|
        rest = if s[2].empty? then "" else opt(subs(s[2])) end
        return "#{s[0]}(.*?)#{rest}"
      end
    end
    return /^#{subs(format)}$/
  end
end



class VirtualContext
  attr_reader :allfields

  def initialize(defs)
    @defs = defs
    @values = {}
    @allfields = []
    @coll = nil
    @curridx = nil
  end

  def append_values(values)
    @values.merge!(values)
  end

  def append_allfields(fields)
    @allfields.concat(fields)
  end

  def set_current_index(idx)
    @curridx = idx
  end

  def curr()
    return @defs[@curridx]
  end

  # return next def to complete (don't go further than last)
  def next()
    idx  = @curridx
    idx += 1 unless full?
    return @defs[idx]
  end

  def full?()
    return @curridx == @defs.size - 1
  end

  def coll()
    @coll = make_coll_filters(@values) if @coll.nil?
    return @coll
  end


  private

  # Build a coll structure that matches conditions in a Hash
  def make_coll_filters(values)
    coll = Xmms::Collection.universe
    unless values.empty?
      values.each do |field, val|
        matchop = make_coll_operator(field, val)
        matchop.operands << coll
        coll = matchop
      end
    end
    return coll
  end

  # Auto-guess whether it should be an exact or partial match
  def make_coll_operator(field, value)
    if value.match(/[*?]/)
      type = Xmms::Collection::TYPE_MATCH
    else
      type = Xmms::Collection::TYPE_EQUALS
    end

    op = Xmms::Collection.new(type)
    op.attributes["field"] = field
    op.attributes["value"] = value.gsub(/\*/, '%').gsub(/\?/, '_')
    return op
  end
end



# check args
unless ARGV.size == 2
  puts "usage: browse.rb <complete|browse|search> PATH"
  exit(1)
end

# hello XMMS2
x2 = Xmms::Client.new("browse")
x2.connect

# Load grammmar from file
vp = VirtualPaths.new(x2)
fp = File.open("vpaths.conf")
while(line = fp.gets)
  line.scan(/(.*?) = (.*)/) do |action, path|
    vp.add_rule(action, path)
  end
end

arg = ARGV[1]

# display corresponding result
case ARGV[0]
when "complete"
  vp.complete_current(arg)
when "browse"
  vp.list_next(arg)
when "search"
  vp.list_entries(arg)
else
  puts "Invalid action: #{ARGV[0]}"
  exit(1)
end

exit(0)


# TODO:
# - list/match actions
# - differentiate complete/browse/search
#   * complete: propose the possible completions of the path.
#   * browse: complete the next path element.
#   * search: display the entries matching the path.
# - cannot match path tokens with multiple elems if only one is given
#   ( e.g. .../Heroes/1* )
# - what output format to use when searching with an incomplete path?
#   just ${n} - ${title}, or the whole missing path e.g. ${album}/${n} - ${title} ?
# - tie to shell completion


# TESTS:
# vp.browse("//")
# vp.browse("//Artists/")
# vp.browse("//Artists/Air")
# vp.browse("//Artists/Air/")
# vp.browse("//Artists//Pocket*")

# vp.complete("//Arti")
# vp.complete("//Albums/Moon")
# vp.complete("//Albums/Moon Safari/")
# vp.complete("//Albums/Moon Safari/01")
# vp.complete("//Albums//")
# vp.complete("//Albums//04")
