---@class avante.LRUCacheNode
---@field key any
---@field value any
---@field prev? avante.LRUCacheNode
---@field next? avante.LRUCacheNode

---@class avante.LRUCache
---@field capacity integer
---@field cache table<any, avante.LRUCacheNode>
---@field head? avante.LRUCacheNode
---@field tail? avante.LRUCacheNode
---@field size integer
local LRUCache = {}
LRUCache.__index = LRUCache

---@param capacity integer
---@return avante.LRUCache
function LRUCache:new(capacity)
  return setmetatable({
    capacity = capacity,
    cache = {},
    head = nil,
    tail = nil,
    size = 0,
  }, LRUCache)
end

-- Internal function: Move node to head (indicating most recently used)
function LRUCache:_move_to_head(node)
  if self.head == node then return end

  -- Disconnect the node
  if node.prev then node.prev.next = node.next end

  if node.next then node.next.prev = node.prev end

  if self.tail == node then self.tail = node.prev end

  -- Insert the node at the head
  node.next = self.head
  node.prev = nil

  if self.head then self.head.prev = node end
  self.head = node

  if not self.tail then self.tail = node end
end

-- Get value from cache
function LRUCache:get(key)
  local node = self.cache[key]
  if not node then return nil end

  self:_move_to_head(node)

  return node.value
end

-- Set value in cache
function LRUCache:set(key, value)
  local node = self.cache[key]

  if node then
    node.value = value
    self:_move_to_head(node)
  else
    node = { key = key, value = value }
    self.cache[key] = node
    self.size = self.size + 1

    self:_move_to_head(node)

    if self.size > self.capacity then
      local tail_key = self.tail.key
      self.tail = self.tail.prev
      if self.tail then self.tail.next = nil end
      self.cache[tail_key] = nil
      self.size = self.size - 1
    end
  end
end

-- Remove specified cache entry
function LRUCache:remove(key)
  local node = self.cache[key]
  if not node then return end

  if node.prev then
    node.prev.next = node.next
  else
    self.head = node.next
  end

  if node.next then
    node.next.prev = node.prev
  else
    self.tail = node.prev
  end

  self.cache[key] = nil
  self.size = self.size - 1
end

-- Get current size of cache
function LRUCache:get_size() return self.size end

-- Get capacity of cache
function LRUCache:get_capacity() return self.capacity end

-- Print current cache contents (for debugging)
function LRUCache:print_cache()
  local node = self.head
  while node do
    print(node.key, node.value)
    node = node.next
  end
end

function LRUCache:keys()
  local keys = {}
  local node = self.head
  while node do
    table.insert(keys, node.key)
    node = node.next
  end
  return keys
end

return LRUCache
