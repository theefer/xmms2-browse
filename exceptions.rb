
class InvalidPathException < RuntimeError
  def initialize(msg)
    super(msg)
  end
end

class NotVirtualPathException < InvalidPathException
  def initialize(name)
    super(name)
  end
end

class InvalidActionException < InvalidPathException
  def initialize(name)
    super(name)
  end
end


class InvalidRuleException < RuntimeError
  def initialize(msg)
    super(msg)
  end
end

class DuplicateRuleException < InvalidRuleException
  def initialize(name)
    super("Duplicate rule '#{name}' ignored!")
  end
end

class BadRefRuleException < InvalidRuleException
  def initialize(name, ref)
    super("Rule '#{name}' references undefined rule '#{ref}'")
  end
end
