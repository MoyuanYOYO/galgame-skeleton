class_name RollbackBuffer
extends RefCounted

## 回滚缓冲
##
## 存最近若干「对白 / 选项节点」的完整状态快照，让玩家用滚轮在历史里前后移动。
##
## 只负责**存与游标**，不碰任何节点、不知道快照里装的是什么 ——
## 所以它能脱离场景单独做单元测试。
##
## 两个容易搞错的地方：
##
## 1. **前进 / 回退后又被新剧情覆盖，必须丢弃「未来」那一截。**
##    玩家回退三句改了选项，那三句之后的旧历史已经作废；
##    如果还留着，再往前翻会翻进一条不存在的分支。
##
## 2. **_cursor 是「当前正在显示的那一格」，不是「下一格」。**
##    空缓冲时是 -1，这个取值要和 can_back() / can_forward() 的判断对齐。

const DEFAULT_CAPACITY := 100

var capacity: int = DEFAULT_CAPACITY

var _items: Array = []
var _cursor: int = -1


func _init(capacity_: int = DEFAULT_CAPACITY) -> void:
	capacity = maxi(1, capacity_)


# ---------------------------------------------------------------------------
# 写入
# ---------------------------------------------------------------------------

## 推入一份新快照，并把游标移到它上面。
##
## 若此前处在「回退过的位置」，先砍掉它之后的所有快照 —— 那是作废的分支。
func push(snapshot: Dictionary) -> void:
	if _cursor >= 0 and _cursor < _items.size() - 1:
		_items = _items.slice(0, _cursor + 1)
	_items.append(snapshot)
	# 超出容量就丢最旧的，游标始终停在最后一格
	while _items.size() > capacity:
		_items.remove_at(0)
	_cursor = _items.size() - 1


func clear() -> void:
	_items.clear()
	_cursor = -1


# ---------------------------------------------------------------------------
# 游标移动
# ---------------------------------------------------------------------------

## 回退一格。返回要还原的快照；已经到头则返回空字典。
func back() -> Dictionary:
	if not can_back():
		return {}
	_cursor -= 1
	return _items[_cursor]


## 前进一格（撤销一次回退）。返回要还原的快照；已经是最后一格则返回空字典。
func forward() -> Dictionary:
	if not can_forward():
		return {}
	_cursor += 1
	return _items[_cursor]


func can_back() -> bool:
	return _cursor > 0


func can_forward() -> bool:
	return _cursor >= 0 and _cursor < _items.size() - 1


# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

func size() -> int:
	return _items.size()


func is_empty() -> bool:
	return _items.is_empty()


func cursor() -> int:
	return _cursor


## 当前显示的那一格。空缓冲返回空字典。
func current() -> Dictionary:
	return at(_cursor)


## 按序号取（0 = 最旧）。越界返回空字典。
func at(index: int) -> Dictionary:
	if index < 0 or index >= _items.size():
		return {}
	return _items[index]
