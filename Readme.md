# VRChat
Collection of useful vrchat items :
- shaders (most of this git currently)
- scripts
- prefabs (maybe later)

## Link database (Unity, Blender, high-level)

Official docs https://docs.vrchat.com/ + link to current Unity version

### Prefabs and tools
- List of many prefabs : https://vrcprefabs.com/
- VRLabs prefabs https://github.com/VRLabs

### Tools
- Avatar optimizer https://github.com/d4rkc0d3r/d4rkAvatarOptimizer
- AnimatorAsCode : animator/animation generator from a CSharp description https://github.com/hai-vr/av3-animator-as-code
- Face tracking blendtree generator https://github.com/rrazgriz/VRCFTGenerator/blob/main/VRCFTGenerator.cs

### Shader frameworks
- Orels modular shader (code based) : https://shaders.orels.sh/
- Poiyomi modular shader (Gui-based, user friendly) : https://www.poiyomi.com/
    - module examples : https://github.com/triazo/Poiyomi-Modules
    - module system : https://github.com/VRLabs/Modular-Shader-System

### Avatar from scratch
- Text source with lots of details for bone naming, tool usage : https://ask.vrchat.com/t/guide-newbie-friendly-guide-for-making-a-custom-avatar-from-scratch/3633
- Blender for vrchat avatar https://www.youtube.com/c/RainhetChaneru/videos
- mesh import plugins https://github.com/johnzero7/XNALaraMesh

### VRChat/Unity
- Blendtree example https://www.youtube.com/watch?v=EkVlkrQ6ypE
- Collider layers : http://vrchat.wikidot.com/worlds:layers
- Physbones : https://www.youtube.com/watch?v=PTTnWUkswkU
- Projectors (map only) :
    - https://docs.unity3d.com/Manual/visual-effects-decals.html
    - https://en.wikibooks.org/wiki/Cg_Programming/Unity/Projectors
    - https://forum.unity.com/threads/where-to-get-the-shaders-for-projector-component.1375395/
    - Alternate depth overlaying : https://www.ronja-tutorials.com/post/054-unlit-dynamic-decals/

### Tool devs and link dbs
- Hai https://hai-vr.notion.site/hai-vr/Knowledge-Index-f53af3099f414e2080b1c0a7425b54e5
- https://vrclibrary.com/wiki/
- Silent : tools, shaders : https://github.com/s-ilent
- HFCred (benchmarks, directblendtree) https://notes.sleightly.dev/
- PiMaker : RiscV emulator https://blog.pimaker.at/texts/rvc1/ ; https://github.com/pimaker
- SCRN : ML models as shaders https://github.com/scrn-vrc

### Shaders
Shader basics
- MVP transforms https://jsantell.com/model-view-projection/
- Transforms again https://en.wikibooks.org/wiki/Cg_Programming/Vertex_Transformations
- Normal transforms : https://forum.unity.com/threads/difference-between-unityobjecttoworlddir-and-unityobjecttoworldnormal.435302/
- Shader tips : https://github.com/cnlohr/shadertrixx

Unity shader fondamentals and integration
- https://docs.unity3d.com/Manual/SL-VertexFragmentShaderExamples.html
- https://www.alanzucconi.com/2015/07/01/vertex-and-fragment-shaders-in-unity3d/
- semantics https://docs.unity3d.com/2019.4/Documentation/Manual/SL-ShaderSemantics.html
- material properties https://docs.unity3d.com/ScriptReference/MaterialPropertyDrawer.html https://docs.unity3d.com/Manual/SL-PropertiesInPrograms.html

Examples
- https://github.com/netri/Neitri-Unity-Shaders#types

Shadowcasters
- https://forum.unity.com/threads/custom-shadow-caster-and-collector-pass.1141900/

Shading
- Blender baking example for bevel and AO maps : https://www.youtube.com/watch?v=-VrYME9-_xU
- Normal work http://www.aversionofreality.com/blog/2022/4/21/custom-normals-workflow

Raymarching
- Sphere impostor https://bgolus.medium.com/rendering-a-sphere-on-a-quad-13c92025570c

Geometry shader
- Examples https://github.com/keijiro/StandardGeometryShader/blob/master/Assets/StandardGeometry.cginc
- Performance insights http://www.joshbarczak.com/blog/?p=667

*Signed Distance Function* (SDF) textures for sharp bitmaps
- Initial article by Valve https://steamcdn-a.akamaihd.net/apps/valve/2007/SIGGRAPH2007_AlphaTestedMagnification.pdf
- Multi channel example https://www.shadertoy.com/view/NtdyWj
- Multi channel tool and pdf doc : https://github.com/Chlumsky/msdfgen/

[Tessellation](shaders/geometry_augmentation/Readme.md)
