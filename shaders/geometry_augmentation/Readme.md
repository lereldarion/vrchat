# Context
Shaders from my experiments with geometry augmentation, using :
- Phong tessellation
- PN triangle / PN quad tessellation

Skeletons are the minimum code to enable DX11 tessellation.

Phong / PN tessellation aims to add geometry following abstract curves defined from the normals.

3 versions have been tested. None have a working shadowcaster so shadows are broken :
- Phong on quads, with a pixel perfect criterion (2nd order polynomial, easy to solve) : broken curves due to phong limitations
- PN on quads, pixel perfect criterion (iterative solve as it is a 6th order polynomial), in 2 variants :
    - with the 4 interior control points "full"
    - using `lerp` from edges only, almost the same in practice but cheaper, "Linear"
    - in both case the curve are nice (PN works !), but the pixel-perfection is not working.

## Pixel-perfect tessellation
In both cases the pixel-perfect criterion idea is to tessellate enough, so that the *screenspace* error between the tessellated edge and its abstract curve is less than a pixel.
This criteria is very general, as it represents exactly what we want.
It merges correctly the combination of distance, view angle, edge curvature.
However it is more expensive to compute than a simple distance based lerp (which is not divergent...), and the visual results are underwhelming compared to the engineering spent on it...

## Normals
Normals must be smooth so that edge normals are not split and the tessellation on both side of each edge agrees with the one on the other side.
Tests were made with a 2nd set of normals (in vertex color) to guide the tessellation direction independently of lighting normals.
The python script can be used in blender to create these vertex color normals.
In practice the precision limitations of the color field create gaps in the meshes ; not great.

## Quad VS Triangles
Most tessellation seen in the field tessellates from triangles.
My test meshes are very low poly, and geometry augmentation using triangles generates visual artefacts due to the face triangulation by blender/unity.
Thus I focused on tessellating from quads, which have more topology data than triangles and generate less artefacts.
Documentation on Quad tessellation is very sparse, so these can serve as examples on the web.

Vrchat accepts non-triangulated quad meshes, just select `keep quad` in the fbx imported window.

There is no easy way to detect a triangle in the quad tessellation framework.
Vertex data fields seems set to 0 but this is not a documented behavior, and a 0 position could be valid data.
In practice this means that the mesh must be quad-only, which is a non-trivial constraint.

## Sources
- Quad phong tessellation https://liris.cnrs.fr/Documents/Liris-6161-phong_tess.pdf
-  https://www.cise.ufl.edu/research/SurfLab/papers/1008PNquad.pdf
- Tessellation introduction https://nedmakesgames.medium.com/mastering-tessellation-shaders-and-their-many-uses-in-unity-9caeb760150e
- Tessellation factor semantics, useful for quads : https://www.reedbeta.com/blog/tess-quick-ref/
- Projection matrices https://jsantell.com/3d-projection/
- Archived reference https://microsoft.github.io/DirectX-Specs/d3d/archive/D3D11_3_FunctionalSpec.htm#HullShader
- Good practices from nvidia https://developer.download.nvidia.com/whitepapers/2010/PN-AEN-Triangles-Whitepaper.pdf
