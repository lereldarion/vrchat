# Automatically create a blendshape that packs blocks in various positions to a dense block
# This could be done manually for sword due to few rotations, but too tedious for other shapes.
# 
# From an object, add a blendshape where blocks (selected by material) are reconfigured in a dense block.
# Block reconfiguration is randomized. Big packs of blocks moving the same are less interesting.
# Triangles can use two orientations with identical output block ; select the one with closest orientation to lessen degenerated blocks during transition.
#
# Final orientation is selected from positions given in a reference object.
# This object should be placed in the target orientation of the pack requested.
# Reference object origin should be the barycenter of blocks ; its +x is tiling direction, +y stacking direction.
#
# Elements using this blendshape generator :
# - shield on the left arm

import typing
import random
import collections

import bpy # blender api
import mathutils # matrix stuff

def vec(v: mathutils.Vector, dim: int) -> mathutils.Vector:
    assert len(v) == dim
    return v.copy().freeze()

VertexData = collections.namedtuple('VertexData', ['index', 'position', 'uv'])
Triangle = typing.List[VertexData]
TrianglePositions = typing.List[mathutils.Vector]

def list_of_block_triangles(object: bpy.types.Object) -> typing.List[Triangle]:
    block_material_index: int = object.material_slots['block_lod0_pbr'].slot_index
    uvs = object.data.uv_layers["UVMap"].data
    
    triangles = []
    for loop_triangle in object.data.loop_triangles:
        if loop_triangle.material_index == block_material_index:
            vertices = []
            for loop_id in loop_triangle.loops:
                loop = object.data.loops[loop_id]
                vertices.append(VertexData(
                    index=loop.vertex_index,
                    position=vec(object.data.vertices[loop.vertex_index].co, 3),
                    uv=vec(uvs[loop_id].uv, 2)
                ))
            assert len(vertices) == 3
            vertices.sort(key = lambda v: v.uv.y) # triangle space uv layout, [bottom, left, top_right]
            triangles.append(vertices)
    return triangles

def select_triangle_with_closest_orientation(target: Triangle, candidates: typing.List[TrianglePositions]) -> TrianglePositions:
    # triangle space uv layout
    [bottom, left, top_right] = target
    (tv0, tv1) = (left.position - bottom.position, top_right.position - bottom.position)
    def orientation_distance_to_target(candidate: TrianglePositions) -> float:
        [bottom, left, top_right] = candidate
        (cv0, cv1) = (left - bottom, top_right - bottom)
        return (cv0 - tv0).length_squared + (cv1 - tv1).length_squared
    return min(candidates, key = orientation_distance_to_target)

if __name__ == "__main__":
    # objects
    reference: bpy.types.Object = bpy.context.collection.objects["packing_blendshape_reference"]
    object: bpy.types.Object = bpy.context.collection.objects["2_shield"]
    
    # parameters
    tiling_vector = mathutils.Vector((0.026, 0, 0)) # 2.6cm ; blender configured for 1 'unit' = 1m
    tiling_length: int = 8
    stacking_vector = mathutils.Vector((0, 0.006, 0)) # 6mm

    # prepare reference data ; project to object space
    reference_triangles = list_of_block_triangles(reference)
    reference_to_object = reference.matrix_world @ object.matrix_world.inverted()
    def to_object_space_positions(vertex: VertexData) -> mathutils.Vector:
        object_position = reference_to_object @ vertex.position.to_4d()
        return vec(object_position.to_3d(), 3)
    
    reference_triangles: TrianglePositions = [[to_object_space_positions(v) for v in triangle] for triangle in reference_triangles]
    tiling_vector = reference_to_object.to_3x3() @ tiling_vector
    stacking_vector = reference_to_object.to_3x3() @ stacking_vector

    # select object triangles
    object_block_triangles = list_of_block_triangles(object)
    random.shuffle(object_block_triangles) # in place

    # new blendshape
    blendshape = object.shape_key_add(name = 'Pack', from_mix = False)
    blendshape.interpolation = 'KEY_LINEAR'

    for i, object_triangle in enumerate(object_block_triangles):
        triangle_model = select_triangle_with_closest_orientation(object_triangle, reference_triangles)
        stacking, tiling = divmod(i, tiling_length)
        displacement = tiling * tiling_vector + stacking * stacking_vector
        for object_vertex, reference_position in zip(object_triangle, triangle_model):
            blendshape.data[object_vertex.index].co = displacement + reference_position

