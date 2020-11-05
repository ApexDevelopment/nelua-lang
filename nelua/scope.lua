local class = require 'nelua.utils.class'
local types = require 'nelua.types'
local typedefs = require 'nelua.typedefs'
local symdefs = require 'nelua.symdefs'
local tabler = require 'nelua.utils.tabler'
local config = require 'nelua.configer'.get()
local console = require 'nelua.utils.console'

local Scope = class()

function Scope:_init(parent, node)
  assert(parent)
  self.node = node
  if parent._context then -- the parent is a context
    self.context = parent
    self.is_root = true
    self.is_returnbreak = true
  else
    self.parent = parent
    self.context = parent.context
    table.insert(parent.children, self)
  end
  self.pragmas = setmetatable({}, {__index = parent.pragmas})
  self.unresolved_symbols = {}
  self.children = {}
  self.labels = {}
  if parent and parent.is_root then
    self.is_topscope = true
  end
  self:clear_symbols()
end

function Scope:fork(node)
  return Scope(self, node)
end

-- Clear the symbols and saved resolution data for this scope.
function Scope:clear_symbols()
  if self.parent then
    self.symbols = setmetatable({}, {__index = self.parent.symbols})
  else
    self.symbols = setmetatable({}, {
      __index =  function(symbols, key)
        -- return predefined symbol definition if nothing is found
        local symbol = symdefs[key]
        if symbol then
          symbol = symbol:clone()
          symbol.scope = self.context.rootscope
          symbols[key] = symbol
          return symbol
        end
      end
    })
  end
  self.possible_rettypes = {}
  self.resolved_rettypes = {}
  self.has_unknown_return = nil
end

-- Search for a up scope matching a property.
function Scope:get_up_scope_of_kind(kind)
  local scope = self
  while scope and not scope[kind] do
    scope = scope.parent
  end
  return scope
end

-- Search for a up scope matching any property.
function Scope:get_up_scope_of_any_kind(kind1, kind2)
  local scope = self
  while scope and not (scope[kind1] or scope[kind2]) do
    scope = scope.parent
  end
  return scope
end

-- Return the first upper scope that is a function.
function Scope:get_up_function_scope()
  if not self.upfunctionscope then
    self.upfunctionscope = self:get_up_scope_of_kind('is_function')
  end
  return self.upfunctionscope
end

-- Return the first upper scope that would process return statements.
function Scope:get_up_return_scope()
  if not self.upreturnscope then
    self.upreturnscope = self:get_up_scope_of_kind('is_returnbreak')
  end
  return self.upreturnscope
end

-- Search for labels backtracking upper scopes.
function Scope:find_label(name)
  local parent = self
  repeat
    local label = parent.labels[name]
    if label then
      return label
    end
    parent = parent.parent
  until (not parent or parent.is_returnbreak)
  return nil
end

function Scope:add_label(label)
  self.labels[label.name] = label
end

function Scope:make_checkpoint()
  local checkpoint = {
    symbols = tabler.copy(self.symbols),
    possible_rettypes = tabler.copy(self.possible_rettypes),
    resolved_rettypes = tabler.copy(self.resolved_rettypes),
    has_unknown_return = self.has_unknown_return
  }
  if self.parent and not self.parent.is_root then
    checkpoint.parentcheck = self.parent:make_checkpoint()
  end
  return checkpoint
end

function Scope:set_checkpoint(checkpoint)
  tabler.clear(self.symbols)
  tabler.clear(self.possible_rettypes)
  tabler.clear(self.resolved_rettypes)
  tabler.update(self.symbols, checkpoint.symbols)
  tabler.update(self.possible_rettypes, checkpoint.possible_rettypes)
  tabler.update(self.resolved_rettypes, checkpoint.resolved_rettypes)
  self.has_unknown_return = checkpoint.has_unknown_return
  if checkpoint.parentcheck then
    self.parent:set_checkpoint(checkpoint.parentcheck)
  end
end

function Scope:merge_checkpoint(checkpoint)
  tabler.update(self.symbols, checkpoint.symbols)
  tabler.update(self.possible_rettypes, checkpoint.possible_rettypes)
  tabler.update(self.resolved_rettypes, checkpoint.resolved_rettypes)
  self.has_unknown_return = checkpoint.has_unknown_return
  if checkpoint.parentcheck then
    self.parent:merge_checkpoint(checkpoint.parentcheck)
  end
end

function Scope:push_checkpoint(checkpoint)
  if not self.checkpointstack then
    self.checkpointstack = {}
  end
  table.insert(self.checkpointstack, self:make_checkpoint())
  self:set_checkpoint(checkpoint)
end

function Scope:pop_checkpoint()
  local oldcheckpoint = table.remove(self.checkpointstack)
  assert(oldcheckpoint)
  self:merge_checkpoint(oldcheckpoint)
end

function Scope:add_symbol(symbol)
  local key
  if not symbol.annonymous then
    key = symbol.name
  else
    key = symbol
  end
  local symbols = self.symbols
  local oldsymbol = symbols[key]
  if oldsymbol then
    if oldsymbol == symbol then
      return true
    end
    -- shadowing a symbol with the same name
    if oldsymbol == self.context.state.inpolydef then
      -- symbol definition of a poly function
      key = symbol
    else
      -- shadowing an usual variable
      if rawget(symbols, key) == oldsymbol then
        -- this symbol will be overridden but we still need to list it for the resolution
        symbols[oldsymbol] = oldsymbol
      end
      symbol.shadows = true
    end
  end
  symbols[key] = symbol -- store by key
  symbols[#symbols+1] = symbol -- store in order
  if not symbol.type and not self.unresolved_symbols[symbol] then
    self.unresolved_symbols[symbol] = true
    self.context.unresolvedcount = self.context.unresolvedcount + 1
  end
  return true
end

function Scope:delay_resolution()
  self.delay = true
end

function Scope:resolve_symbols()
  local unresolved_symbols = self.unresolved_symbols
  if not next(unresolved_symbols) then return 0 end

  local count = 0
  local unknownlist = {}
  -- first resolve any symbol with known possible types
  for symbol in next,unresolved_symbols do
    if symbol.type == nil then
      if symbol:resolve_type() then
        count = count + 1
      elseif count == 0 then
        unknownlist[#unknownlist+1] = symbol
      end
    end
    if symbol.type then
      unresolved_symbols[symbol] = nil
      self.context.unresolvedcount = self.context.unresolvedcount - 1
    end
  end
  -- if nothing was resolved previously then try resolve symbol with unknown possible types
  if count == 0 and #unknownlist > 0 and not self.context.rootscope.delay then
    -- [disabled] try to infer the type only for the first unknown symbol
    --table.sort(unknownlist, function(a,b) return a.node.pos < b.node.pos end)
    for i=1,#unknownlist do
      local symbol = unknownlist[i]
      local force = self.context.state.anyphase and typedefs.primtypes.any or not symbol:is_waiting_resolution()
      if symbol:resolve_type(force) then
        unresolved_symbols[symbol] = nil
        self.context.unresolvedcount = self.context.unresolvedcount - 1
        count = count + 1
      end
      --break
    end
  end
  return count
end

function Scope:resolve_symbol(symbol)
  if self.unresolved_symbols[symbol] and symbol:resolve_type() then
    self.unresolved_symbols[symbol] = nil
    self.context.unresolvedcount = self.context.unresolvedcount - 1
  end
end

function Scope:add_return_type(index, type)
  if not type then
    self.has_unknown_return = true
  end
  local rettypes = self.possible_rettypes[index]
  if not rettypes then
    self.possible_rettypes[index] = {[1] = type}
  elseif type and not tabler.ifind(rettypes, type) then
    rettypes[#rettypes+1] = type
  end
end

function Scope:resolve_rettypes()
  local count = 0
  if not next(self.possible_rettypes) then return count end
  local resolved_rettypes = self.resolved_rettypes
  resolved_rettypes.has_unknown = self.has_unknown_return
  for i,rettypes in pairs(self.possible_rettypes) do
    resolved_rettypes[i] = types.find_common_type(rettypes) or typedefs.primtypes.any
    count = count + 1
  end
  return count
end

function Scope:resolve()
  local count = self:resolve_symbols()
  self:resolve_rettypes()
  if count > 0 and config.debug_scope_resolve then
    console.info(self.node:format_message('info', "scope resolved %d symbols", count))
  end
  if self.delay then
    self.delay = false
    count = count + 1
  end
  self.resolved_once = true
  return count
end

return Scope
