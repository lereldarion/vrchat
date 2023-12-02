import typing
import collections
import itertools
import sys
import enum
import math
import random

import bpy # blender api
import mathutils # matrix stuff

class FloatN:
    """Printing helper for float2/3/4"""
    def __init__(self, v: typing.Sequence) -> None:
        self.v = v
    def __str__(self) -> str:
        return f"float{len(self.v)}({', '.join(str(item) for item in self.v)})"

VertexData = collections.namedtuple('VertexData', ['index', 'position', 'normal', 'tangent', 'uv'])

def approx_equal(a: mathutils.Vector, b: mathutils.Vector, relative_threshold: float = 0.0001):
    return all(abs(a_i - b_i) <= relative_threshold * abs(max(a_i, b_i)) for a_i, b_i in zip(a, b))

def generate_random_table(output):
    n = 64
    print ("// random constants float4(float3 vector, float speed)", file=output)
    print (f"static const uint nb_baked_random_constants = {n};", file=output)
    print (f"static const float4 baked_random_constants[{n}] = {{", file=output)
    for _ in range(n):
        v = tuple(random.normalvariate(mu = 0., sigma = 1.) for _ in range(3))
        print (f"    {FloatN((*v, random.normalvariate(mu = 0., sigma = 4.)))},", file=output)
    print (f"}};\n", file=output)

### Space transforms

def build_transformation_matrices(triangle: bpy.types.Object, block: bpy.types.Object) -> typing.Tuple[mathutils.Matrix, mathutils.Matrix]:
    # get 4x4 homogeneous space matrices
    triangle_os_to_ws = triangle.matrix_world
    block_os_to_ws = block.matrix_world
    # extract triangle parameters
    t_mesh: bpy.types.Mesh = triangle.data
    t_mesh.calc_tangents()
    triangle_uvs = t_mesh.uv_layers["UVMap"].data
    [polygon] = t_mesh.polygons
    def vertice_data_from_loop(id: int) -> VertexData:
        loop = t_mesh.loops[id]
        return VertexData(
            index = loop.vertex_index, position = t_mesh.vertices[loop.vertex_index].co,
            normal = loop.normal, tangent = loop.tangent,
            uv = triangle_uvs[id].uv
        )
    vertices = [vertice_data_from_loop(id) for id in polygon.loop_indices]
    # Triangle space that support elongation without rotation, based on positions only.
    # Build the space from positions, by normalising with the length of the small side of the triangle.
    # Normal is infered by cross, so its direction does not matter ; uv are enough to orient the stuff.
    vertices.sort(key = lambda v: v.uv.y)
    [bottom, left, top_right] = vertices # From uv layout
    ts_origin_os = (bottom.position + left.position + top_right.position) / 3.
    ts_y_os = left.position - bottom.position
    normalized_x = (top_right.position - ts_origin_os).normalized() # due to triangle symmetry this is normal to y.
    ts_x_os = normalized_x * ts_y_os.length
    ts_z_os = mathutils.Vector.cross(normalized_x, ts_y_os) # cross(x,y) normalized with y scaling ; always oriented correctly
    # matrix ; beware as indexes are row by default
    ts_to_os = mathutils.Matrix.Identity(4)
    ts_to_os.col[0][0:3] = ts_x_os
    ts_to_os.col[1][0:3] = ts_y_os
    ts_to_os.col[2][0:3] = ts_z_os
    ts_to_os.col[3][0:3] = ts_origin_os
    # we need from block to ts
    os_to_ts = ts_to_os.inverted()
    block_os_to_ts = os_to_ts @ triangle_os_to_ws.inverted() @ block_os_to_ws
    # uv space projection. project in ts, ignore z, and find matrix m such that m * colvec(p.xy1) = colvec(p.uv)
    # thus m = (matrix of p.uv, 3x2) * inverse(matrix of p.xy1, 3x3)
    xy1_matrix = mathutils.Matrix.Identity(3)
    uv_matrix = mathutils.Matrix([[0] * 3] * 2)
    for col, (pos, uv) in enumerate([(os_to_ts @ v.position, v.uv) for v in vertices]):
        assert pos.z == 0 # ts aligned with triangle plane
        xy1_matrix.col[col] = (pos.x, pos.y, 1.) # Beware, Vector.to_Nd() fills z with 0, w with 1
        uv_matrix.col[col] = uv
    ts_xy1_to_uv = uv_matrix @ xy1_matrix.inverted()
    assert (len(ts_xy1_to_uv.row), len(ts_xy1_to_uv.col)) == (2, 3)
    return (block_os_to_ts, ts_xy1_to_uv)

def _triangle_space_definition_with_tangent_space():
    # old definition, using the tangent space provided by unity.
    # pros : nice orthonormal basis, already computed by unity. only uses the multiple points for scaling
    # cons : unity does weird stuff with tangent space, especially with skinning, so lots of unity definitions are needed shader-side. Non uniform scaling is weird, induces rotation.

    # Check that triangle is flat and tangent space is constant
    [a, b, c] = vertices
    assert approx_equal(a.normal, b.normal)
    assert approx_equal(a.normal, c.normal)
    assert approx_equal(a.tangent, b.tangent)
    assert approx_equal(a.tangent, c.tangent)
    # build triangle space reference frame (same definition as shader code)
    ts_origin_os = (a.position + b.position + c.position) / 3.
    def length_squared(v: mathutils.Vector) -> float:
        return mathutils.Vector.dot(v, v)
    scale = math.sqrt(length_squared(a.position - b.position) + length_squared(a.position - c.position) + length_squared(b.position - c.position))
    ts_z_os = a.normal * scale
    ts_y_os = a.tangent * scale
    ts_x_os = mathutils.Vector.cross(a.tangent, a.normal) * scale

### Fix flattened uvs ; only run when triangle space has changed

def set_block_faces_uv_to_triangle_uv(block: bpy.types.Mesh, block_os_to_ts: mathutils.Matrix, ts_xy1_to_uv: mathutils.Matrix):
    block_os_to_ts_dir = block_os_to_ts.to_3x3()
    block.calc_normals_split()
    block_uvs = block.uv_layers["UVMap"].data
    for loop in block.loops:
        normal_ts = (block_os_to_ts_dir @ loop.normal).normalized()
        if abs(normal_ts.z) > 0.5:
            # Only for faces, as more vertical surfaces will not appear on the flat triangle
            # They will use manual uvs outside of the triangle uv space
            pos_ts = block_os_to_ts @ block.vertices[loop.vertex_index].co.to_4d()
            uv = ts_xy1_to_uv @ mathutils.Vector((pos_ts.x, pos_ts.y, 1.))
            if normal_ts.z < 0:
                # Shift backface uv uvs to not overlap for normal map computations.
                uv.x += 1
            block_uvs[loop.index].uv = uv

### Read blender data

TriangulationData = collections.namedtuple('TriangulationData', [
    'nb_use_by_direction_vector', # float3 -> int
    'adjacency', # int -> ((VertexData, VertexData) -> int) ; ints=loop_triangle_index ; VertexData pair sorted
    'vertices_data', # int -> list[VertexData] ; ints=loop_triangle_index
    'normals', # int -> Vector3
])

def scan_block_loop_triangles(block: bpy.types.Mesh) -> TriangulationData:
    block.calc_tangents()
    block_uvs = block.uv_layers["UVMap"].data

    def vec(v: mathutils.Vector, dim: int) -> mathutils.Vector:
        assert len(v) == dim
        return v.copy().freeze()

    # Topology data
    loop_triangle_vertice_data = dict()
    loop_triangle_normal = dict()

    # create a merged set of all used direction vectors(normal, tangent) for sharing common values
    nb_use_by_direction_vector = collections.Counter()

    # create adjacency lists between neighbour triangles only if they actually share vertex data (can be in sequence in the same strip)
    loop_triangle_adjacency = collections.defaultdict(dict) # index: int -> ((VertexData, VertexData) -> index)
    unmatched_edges = {} # (VertexData, VertexData) -> triangle_loop index

    # Scan
    for loop_triangle in block.loop_triangles:
        # scan vertices
        vertices = []
        for loop_id in loop_triangle.loops:
            loop = block.loops[loop_id]
            vertices.append(VertexData(
                index=loop.vertex_index, position=vec(block.vertices[loop.vertex_index].co, 3),
                normal=vec(loop.normal, 3), tangent=vec(loop.tangent, 3),
                uv=vec(block_uvs[loop_id].uv, 2)
            ))
            nb_use_by_direction_vector[vec(loop.normal, 3)] += 1
            nb_use_by_direction_vector[vec(loop.tangent, 3)] += 1
        # vertex data
        assert len(vertices) == 3
        vertices.sort() # ensure order of VertexData pairs and triplets is normalized everywhere
        loop_triangle_vertice_data[loop_triangle.index] = vertices.copy()
        loop_triangle_normal[loop_triangle.index] = loop_triangle.normal
        # adjacency
        for vertice_pair in itertools.combinations(vertices, 2):
            matching_triangle_index = unmatched_edges.get(vertice_pair)
            if matching_triangle_index is not None:
                # assume edge is only bordering 2 triangles ; more would be bad geometry
                loop_triangle_adjacency[matching_triangle_index][vertice_pair] = loop_triangle.index
                loop_triangle_adjacency[loop_triangle.index][vertice_pair] = matching_triangle_index
                del unmatched_edges[vertice_pair]
            else:
                unmatched_edges[vertice_pair] = loop_triangle.index

    return TriangulationData(nb_use_by_direction_vector, dict(loop_triangle_adjacency), loop_triangle_vertice_data, loop_triangle_normal)

### Triangle strips with vertex sequences for the correct winding

class Winding(enum.Enum):
    ClockWise = False
    CounterClockWise = True

    def reversed(self):
        return Winding(not self.value)
    
    @staticmethod
    def face(vertices: typing.List[VertexData], normal: mathutils.Vector):
        [a, b, c] = vertices
        face_ccw_normal = mathutils.Vector.cross(b.position - a.position, c.position - a.position)
        return Winding(mathutils.Vector.dot(face_ccw_normal, normal) > 0)
    
UNITY_WINDING = Winding.ClockWise
    
def vertex_sequence_for_triangle1(triangle_index: int, triangulation: TriangulationData) -> typing.List[VertexData]:
    vertices = triangulation.vertices_data[triangle_index]
    if Winding.face(vertices, triangulation.normals[triangle_index]) == UNITY_WINDING:
        return vertices
    else:
        return [vertices[0], vertices[2], vertices[1]]

def vertex_sequence_for_triangle2(first_triangle_index: int, second_triangle_index: int, triangulation: TriangulationData) -> typing.List[VertexData]:
    # Triangulated quad can still have shared vertices swapped to fit any winding ; fix start triangle and find the right winding order
    vertice_sets = [set(triangulation.vertices_data[index]) for index in [first_triangle_index, second_triangle_index]]
    shared_vertices = set.intersection(*vertice_sets)
    [a] = list(vertice_sets[0] - shared_vertices)
    [d] = list(vertice_sets[1] - shared_vertices)
    [b, c] = list(shared_vertices)
    sequence = [a, b, c, d] if Winding.face([a, b, c], triangulation.normals[first_triangle_index]) == UNITY_WINDING else [a, c, b, d]
    assert Winding.face(sequence[1:], triangulation.normals[second_triangle_index]) == UNITY_WINDING.reversed()
    return sequence

def vertex_sequence_for_triangleN(triangle_indices: typing.List[int], triangulation: TriangulationData) -> typing.List[VertexData]:
    # check end triangles in forward and reverse order, one will match
    assert len(triangle_indices) >= 3
    def winded_first_triangle_vertices(triangle_indices):
        # To start a △▽△+ strip [a, b, c], the first triangle vertex order can be identified by their connection to triangles: [a, ab, abc]
        [a, b, c] = triangle_indices[:3]
        vertice_and_counts = [
            (vertex, int (vertex in triangulation.vertices_data[b]) + int(vertex in triangulation.vertices_data[c]))
            for vertex in triangulation.vertices_data[a]
        ]
        vertice_and_counts.sort(key = lambda v_and_c: v_and_c[1])
        vertices, counts = zip(*vertice_and_counts)
        assert counts == (0, 1, 2)
        vertices = list(vertices)
        if Winding.face(vertices, triangulation.normals[a]) == UNITY_WINDING:
            return vertices
        else:
            return None
    # Check both sides
    sequence = winded_first_triangle_vertices(triangle_indices)
    if sequence is None:
        triangle_indices.reverse()
        sequence = winded_first_triangle_vertices(triangle_indices)
        assert sequence is not None
    # Build sequence to end ; for each added triangle the next vertex is the one complementing the last two already set
    expected_winding = UNITY_WINDING.reversed()
    for triangle in triangle_indices[1:]:
        [new_vertice] = list(set(triangulation.vertices_data[triangle]) - set(sequence[-2:]))
        assert Winding.face([sequence[-2], sequence[-1], new_vertice], triangulation.normals[triangle]) == expected_winding
        expected_winding = expected_winding.reversed()
        sequence.append(new_vertice)
    return sequence

def divide_into_triangle_strip_vertex_sequences(triangulation: TriangulationData, max_strip_length: int) -> typing.List[typing.List[VertexData]]:
    assert max_strip_length > 3
    max_triangle_count = max_strip_length - 2
    
    remaining_triangles = set(triangulation.adjacency.keys())

    # Pick triangles starting with low connectivity ones : https://old.cescg.org/CESCG-2002/PVanecek/paper.pdf
    def priority(triangle_index: int) -> float:
        # Inverse of local "connectivity", ignoring already handled triangles (not connectable to a strip anymore)
        return -sum(1 + 0.5 * len(triangulation.adjacency[neighbor]) for neighbor in triangulation.adjacency[triangle_index].values() if neighbor in remaining_triangles)
    
    # Process strips    
    strips = []
    while len(remaining_triangles) > 0:
        # start strip with lowest connectivity triangle left
        first_index = max(remaining_triangles, key = priority)
        remaining_triangles.remove(first_index)

        # try extend on any side
        second_index = max(
            (index for index in triangulation.adjacency[first_index].values() if index in remaining_triangles),
            default = None, key = priority
        )
        if second_index is None or max_triangle_count == 1:
            strips.append(vertex_sequence_for_triangle1(first_index, triangulation))
            continue
        remaining_triangles.remove(second_index)

        # extend on 2 free edges of each triangles. will not try on the shared edge as both (first, second) are out of remaining_triangles
        candidates = (
            [(index, [index, first_index, second_index]) for index in triangulation.adjacency[first_index].values() if index in remaining_triangles] +
            [(index, [first_index, second_index, index]) for index in triangulation.adjacency[second_index].values() if index in remaining_triangles]
        )
        choice = max(candidates, default = None, key = lambda candidate: priority(candidate[0]))
        if choice is None or max_triangle_count == 2:
            strips.append(vertex_sequence_for_triangle2(first_index, second_index, triangulation))
            continue
        third_index, triangles = choice
        remaining_triangles.remove(third_index)

        # at 3 = △▽△ or ▽△▽ we only have one choice at each end that is still a 'strip' and not a 'fan',
        def extend_triangle_strip_right(triangles: typing.List[int]) -> bool:
            while len(triangles) < max_triangle_count:
                last_triangles = triangles[-3:] # Only look at last 3
                last_triangle = last_triangles[2]
                [central_vertex] = list(set.intersection(*[set(triangulation.vertices_data[index]) for index in last_triangles]))
                shared_edge_vertices = triangulation.vertices_data[last_triangle].copy() # all edges of right triangle, ordered
                shared_edge_vertices.remove(central_vertex) # VertexData pair of the edge we need to take
                next_triangle_index = triangulation.adjacency[last_triangle].get(tuple(shared_edge_vertices))
                if next_triangle_index is None:
                    return
                if next_triangle_index not in remaining_triangles:
                    return
                remaining_triangles.remove(next_triangle_index)
                triangles.append(next_triangle_index)
        # extend both ends
        extend_triangle_strip_right(triangles)
        triangles.reverse()
        extend_triangle_strip_right(triangles)
        strips.append(vertex_sequence_for_triangleN(triangles, triangulation))
    return strips

def strips_length_distribution(strips: typing.List[typing.List[VertexData]]) -> dict:
    return collections.Counter(len(strip) for strip in strips)

### Organize triangle strips into instances

def organize_strips_into_instances(strips: typing.List[typing.List[VertexData]], max_nb_vertice_per_instance: int) -> typing.List[typing.List[typing.List[VertexData]]]:
    assert max_nb_vertice_per_instance >= 3
    # Sort strips by sizes
    strips.sort(key = len, reverse = True)
    assert len(strips[0]) <= max_nb_vertice_per_instance # we can always choose to split strips, but this adds unneeded complications, better to increase instance vertices
    strips_by_size = dict((k, list(strips_len_k)) for k, strips_len_k in itertools.groupby(strips, key = len))
    assert (sys.version_info.major, sys.version_info.minor) >= (3, 7) # ordered dict used https://docs.python.org/3/library/stdtypes.html#dict.popitem
    # Organize strips into instances, very greedily
    finished_instances = []
    unfinished_instance = []
    unfinished_instance_remaining_size = max_nb_vertice_per_instance
    while len(strips_by_size) > 0:
        # pick largest strip that fits the remaining size
        largest_fitting_size = next(filter(lambda s: s <= unfinished_instance_remaining_size, strips_by_size.keys()), None)
        if largest_fitting_size is not None:
            strip_candidates = strips_by_size[largest_fitting_size]
            unfinished_instance.append(strip_candidates.pop())
            unfinished_instance_remaining_size -= largest_fitting_size
            if len(strip_candidates) == 0:
                del strips_by_size[largest_fitting_size]
        else:
            # Instance cannot be expanded
            finished_instances.append(unfinished_instance)
            unfinished_instance = []
            unfinished_instance_remaining_size = max_nb_vertice_per_instance
    if len(unfinished_instance) > 0:
        finished_instances.append(unfinished_instance)
    return finished_instances   

def instance_vertice_lengths(instances: typing.List[typing.List[typing.List[VertexData]]]) -> typing.List[int]:
    return [sum(len(strip) for strip in strips) for strips in instances]

### Output shader code

if __name__ == "__main__":
    # objects
    triangle: bpy.types.Object = bpy.context.collection.objects["triangle"]
    block_lod0: bpy.types.Object = bpy.context.collection.objects["block_lod0"]
    block_lod1: bpy.types.Object = bpy.context.collection.objects["block_lod1"]

    assert block_lod0.matrix_world == block_lod1.matrix_world # Must match as we only have one ts_to_os matrix
    block_os_to_ts, ts_xy1_to_uv = build_transformation_matrices(triangle, block_lod0)

    # Only run if triangle space has changed, as it changes uv and all dependent values (normal maps, etc) must be redone.
    #set_block_faces_uv_to_triangle_uv(block_lod0.data, block_os_to_ts, ts_xy1_to_uv)

    triangulation_lod0 = scan_block_loop_triangles(block_lod0.data)
    triangulation_lod1 = scan_block_loop_triangles(block_lod1.data)

    # Finding the right strip size and split is NP-complete so I am not interested in trying any "optimal" solution algorithmically.
    # For lod0 model, strips = 4x7+12x4 vertices, so using 8 vertice instances leads to 10 instances at 7 or 8 vertices.
    strips_lod0 = divide_into_triangle_strip_vertex_sequences(triangulation_lod0, max_strip_length = 7)
    instances_lod0 = organize_strips_into_instances(strips_lod0, max_nb_vertice_per_instance = 8)
    # lod1 model is tuned to match lod0 sizing, as geometry stage instance count is a constant
    # strips = (2x6|4x4 by forcing splitting)+6x4 vertices, so force splitting the faces to have exactly 10x4 vertice instances
    strips_lod1 = divide_into_triangle_strip_vertex_sequences(triangulation_lod1, max_strip_length = 4)
    instances_lod1 = organize_strips_into_instances(strips_lod1, max_nb_vertice_per_instance = 4)
    
    block_os_to_ts_dir = block_os_to_ts.to_3x3()

    # Instanced geometry data
    with open (bpy.path.abspath ("//geometry_baked_data.hlsl"), "w") as output:
        # Precomputed random table
        generate_random_table(output)
        # Vertex Data from both lod are concatenated so that access only changes offsets in indice array.
        concatenated_instances_nb_vertices = instance_vertice_lengths(instances_lod0 + instances_lod1)
        assert len(instances_lod0) == len(instances_lod1) # In general we should pad if mismatch
        # Geometry stage parameters
        print ("// geometry stage constants ", file=output)
        print (f"static const uint nb_geometry_instances = {len(instances_lod0)};", file=output)
        print (f"static const uint nb_vertices_per_geometry_instance = {max(concatenated_instances_nb_vertices)};\n", file=output)
        # We will build an array of vertex Data, and a list of indice offsets for each instance. Define some types :
        print ("struct BakedVertexData { float3 position_ts; float3 normal_ts; float3 tangent_ts; float2 uv0; bool strip_restart; };", file=output)
        # Vertex Data from both lod are concatenated so that access only changes offsets in indice array
        def print_instance_vertex_data(pad: str, instance_strips: typing.List[typing.List[VertexData]]):
            strip_restart = False # implicit restart at start of geometry stage
            for strip in instance_strips:
                for vertex in strip:
                    position_ts = (block_os_to_ts @ vertex.position.to_4d()).to_3d()
                    normal_ts = block_os_to_ts_dir @ vertex.normal
                    tangent_ts = block_os_to_ts_dir @ vertex.tangent
                    print (f"{pad}{{ {FloatN(position_ts)}, {FloatN(normal_ts)}, {FloatN(tangent_ts)}, {FloatN(vertex.uv)}, {'true' if strip_restart else 'false'} }},", file=output)
                    strip_restart = False
                strip_restart = True

        print (f"static const BakedVertexData geometry_baked_vertex_data[{sum(concatenated_instances_nb_vertices)}] = {{", file=output)
        print ("    // LOD0 data", file=output)
        for instance_strips in instances_lod0:
            print_instance_vertex_data("    ", instance_strips)
        print ("    // LOD1 data", file=output)
        for instance_strips in instances_lod1:
            print_instance_vertex_data("    ", instance_strips)
        print (f"}};\n", file=output)
        # Indices, in the same order ; instance N ends where instance N+1 starts
        instance_data_boundaries = [sum(concatenated_instances_nb_vertices[:i]) for i in range(len(concatenated_instances_nb_vertices) + 1)]
        print (f"static const uint geometry_instance_boundaries[{len(concatenated_instances_nb_vertices) + 1}] = {{ {', '.join(str(i) for i in instance_data_boundaries)} }};", file=output)