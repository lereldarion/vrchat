# Sources for my replicator avatar
Some basic explanations, but this is incomplete (no mesh, texture, unity object tree).

## Geometry compression using geometry pass
Each triangle in the base mesh is dynamically expanded to a replicator block by the shader.
- `generate_shader_code.py` : Generate the HLSL tables of vertex data constants, from blender meshes (the anchor triangle, and blocks for LOD0 and LOD1).
- `baked_geometry_data.hlsl` : Vertex data that is generated.
- `baked_random_values.hlsl` : set of random values to sample from.
- `prototype.shader` : Simple version of the geometry pass expansion code, with debug shading. Uses the vertex data.

## Orels integration
- `template.orltemplate` : Modified PBR template to add a geometry pass and some hooks for the replicator case
- `replicator_pbr.orlsource` : Integration of the strategy as a base orels module. Expands geometry, supports dislocation and hiding blocks, and audiolink. The `_MainTex` is only used for fallback, using a flat cutout profile of the block on the triangle geometry.

## Dislocation
Procedural dislocation that can be triggered by contact points, to cut the arms using a sword
- Arm dislocation uses a distance contact at the elbow to detect the cut point, with a capsule on each side to determine the side.
`ReplicatorConfigureAvatar.cs` computes a `[-1, 1]` coordinate along each arm, and stores it in UVs.
- Global dislocation uses a delay from top to bottom to be progressive, computed by the same script and stored in UVs too.
- Dislocation animation is a rotation + worldspace block displacement (`d(t) = v_init t + (0, 0, -0.5g) t^2`). `v_init` comes from a table of random vectors.
- `avatar.orlshader` : package for the avatar ; defines dislocation modes.

## Pets
There is a close pet replicator with a very simple follower logic, with a physbone to the avatar root space.
This uses normal animations, and the geometry is part of the main avatar skined mesh.

An alternative pet system can spawn up to 4 pets that go in a straight line in worldspace.
These are basic `MeshRenderer`, and the skinning and animation is done in the shader.
The strategy is viable only for very simple bone configurations : 4x1d rotation sequence at most, and vertices with only 1 bone influence each.
- `pet.orlshader` : applies the emulated skinning pass in the vertex shader
- `pet_data.orlsource` : animation frame data (sampled from a real unity animation), and bone configuration for each vertex (bone id stored in UVs)
- `ReplicatorConfigurePet.cs` : creates the tables and sets custom UVs, from a skinned mesh and animations on it. Also mirrors animations so they only need to be set for one side of the pet.

## Animations
Avatar animator is entirely defined with https://github.com/hai-vr/av3-animator-as-code (V0), in `ReplicatorAvatarAnimator.cs`.
It uses direct blend tree when useful to remove simple animator layers.

Many animations *reorganize* blocks, implemented using simple blendshapes.
Unused objects are tightly packed into tiled patterns, but this is tedious to do manually.
`setup_packing_blendshape.py` creates a blendshape to pack blocks automatically, and chooses between the 2 symmetric orientations that reduce the rotation during the blendshape.