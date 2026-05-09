class_name HexUtils

# Pointy-top axial coordinate system.
# size is the circumradius of each hex (center to corner).
const HEX_SIZE: float = 0.5

# Axial (q, r) -> World position (x, z)
static func axial_to_world(q: int, r: int) -> Vector3:
	var x: float = HEX_SIZE * sqrt(3.0) * (q + r * 0.5)
	var z: float = HEX_SIZE * 1.5 * r
	return Vector3(x, 0.0, z)

# Axial neighbor directions (pointy-top)
const NEIGHBOR_DIRS: Array = [
	Vector2i(1,  0),
	Vector2i(1, -1),
	Vector2i(0, -1),
	Vector2i(-1, 0),
	Vector2i(-1, 1),
	Vector2i(0,  1),
]

static func get_neighbors(q: int, r: int) -> Array:
	var result: Array = []
	for d in NEIGHBOR_DIRS:
		result.append(Vector2i(q + d.x, r + d.y))
	return result

static func axial_distance(a: Vector2i, b: Vector2i) -> int:
	return (abs(a.x - b.x) + abs(a.x + a.y - b.x - b.y) + abs(a.y - b.y)) / 2
