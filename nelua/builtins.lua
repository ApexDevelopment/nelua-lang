local builtins = {}
local fs = require 'nelua.utils.fs'
local config = require 'nelua.configer'.get()
local preprocessor = require 'nelua.preprocessor'
local pegger = require 'nelua.utils.pegger'

function builtins.require(context, node)
  local attr = node.attr
  if attr.alreadyrequired or attr.runtime_require then
    -- already tried to load
    return
  end

  local justloaded = false
  if not attr.loadedast then
    local canloadatruntime = context.generator == 'lua'
    local argnode = node[1][1]
    if not (argnode and
            argnode.attr.type and argnode.attr.type.is_stringview and
            argnode.attr.comptime) or not context.scope.is_topscope then
      -- not a compile time require
      if canloadatruntime then
        attr.runtime_require = true
        return
      else
        node:raisef('runtime require unsupported, use require with a compile time string in top scope')
      end
    end

    -- load it and parse
    local unitpath = argnode.attr.value
    local reldir = argnode.src.name and fs.dirname(argnode.src.name) or nil
    local filepath, err = fs.findmodulefile(unitpath, config.path, reldir)
    if not filepath then
      if canloadatruntime then
        -- maybe it would succeed at runtime
        attr.runtime_require = true
        return
      else
        node:raisef("in require: module '%s' not found:\n%s", unitpath, err)
      end
    end

    -- nelua internal libs have unit name of just 'nelua'
    local unitname = pegger.filename_to_unitname(unitpath)
    if filepath:find(config.lib_path, 1, true) then
      unitname = 'nelua'
    end
    attr.unitname = unitname

    local reqnode = context.requires[filepath]
    if reqnode and reqnode ~= node then
      -- already required
      attr.alreadyrequired = true
      return
    end

    local input = fs.ereadfile(filepath)
    local ast = context.parser:parse(input, filepath)
    attr.loadedast = ast

    justloaded = true

    context.requires[filepath] = node
  end

  -- analyze it
  local ast = attr.loadedast
  local state = context:push_state()
  state.unitname = attr.unitname
  context:push_scope(context.rootscope)
  state.inrequire = true
  if justloaded then
    preprocessor.preprocess(context, ast)
  end
  context:traverse_node(ast)
  context:pop_scope()
  context:pop_state()
end

function builtins.check(context, node)
  if context.scope.pragmas.nochecks then
    node.attr.omitcall = true
  end
end

return builtins
