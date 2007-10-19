#!/usr/bin/ruby

require 'xmmsclient'

require './exceptions'


# Handles the rules for virtual paths.
class VirtualPaths

  def initialize()
    @rules = Hash.new
  end

  def add_rule(name, path_spec)
    throw DuplicateRuleException.new(name) if @rules.key?(name)

    if path_spec.match(/^\//)
      @rules[name] = make_rule(path_spec)
    else
      # alias for an existing rule, check existence
      throw BadRefRuleException.new(name, path_spec) unless @rules.key?(path_spec)

      # alias by copying the rule
      @rules[name] = @rules[path_spec]
    end
    self
  end

  def browse(path)
    if parse = path.match(/^\/\/([^\/]*)(.*)/)
      action = parse[1]

      throw String.new("Invalid action '#{action}'!") unless @rules.key?(action)

      # parse context
      return @rules[action].parse(parse[2])
    else
      throw String.new("No match!") unless @rules.key?(action)
    end
  end

  def complete(path)
    # FIXME: do something
  end


  private
  def make_rule(spec)
    throw InvalidRuleException("Empty rule!") if spec.size < 2

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
    elems = path[1..-1].split('/', -1)

    vc = VirtualContext.new
    lastdef = nil

    i = 0
    @defs.zip(elems).map do |d, e|
      lastdef = d

      # register field order
      vc.append_allfields(d.vars)

      # not enough elems, incomplete path
      break if (e.nil? or e.empty?)

      # extract values
      vc.append_values(d.parse_values(e))

      # last token is multimatch, stop to complete it
      break if (i == elems.size - 1 and is_multimatch(e))

      i += 1
    end

    vc.set_next(lastdef.vars, lastdef.format)

    return vc
  end

  private

  # token considered a multimatch if contains wildcard
  def is_multimatch(s)
    return s.match(/[*?]/)
  end

  class RuleItem
    attr_reader :vars, :format

    def initialize(vars, format)
      @vars = vars
      @format = format
    end

    def parse_values(s)
      pattern = @format.gsub(/\$\{(.*?)\}/, '(.*?)')
      match = s.match("^#{pattern}$")

      i = 1
      h = Hash.new
      @vars.each do |v|
        h[v] = match[i]
        i += 1
      end
      return h
    end
  end
end



class VirtualContext
  attr_reader :coll, :nextvars, :allfields, :nextformat

  def initialize()
    @values = {}
    @allfields = []
    @nextvars = []
    @nextformat = ""
    @coll = nil
  end

  def append_values(values)
    @values.merge!(values)
  end

  def append_allfields(fields)
    @allfields.concat(fields)
  end

  def set_next(variables, format)
    @nextvars = variables
    @nextformat = format
  end

  def coll()
    @coll = make_coll_filters(@values) if @coll.nil?
    @coll
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


# Given a context, perform xmms2 actions
class VirtualXmms2Browser
  def initialize(conn)
    @conn = conn
  end

  def list(ctx)
    res = @conn.coll_query_info(ctx.coll, ctx.nextvars, ctx.allfields)
    res.wait
    res.value.each do |dict|
      s = ctx.nextformat.gsub(/\$\{(.*?)\}/) {|| dict[$1.to_sym]}
      puts s
    end
  end
end


x2 = Xmms::Client.new("browse")
x2.connect

# Load grammmar from file
vp = VirtualPaths.new

fp = File.open("vpaths.conf")
while(line = fp.gets)
  line.scan(/(.*?) = (.*)/) do |action, path|
    vp.add_rule(action, path)
  end
end

show = VirtualXmms2Browser.new(x2)


unless ARGV.size == 1
  puts "usage: browse.rb PATH"
  exit(1)
end

ctx = vp.browse(ARGV[0])
show.list(ctx)


# TODO:
# - list/match actions
# - differentiate browse vs completion
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
