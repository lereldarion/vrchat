// UNITY_SHADER_NO_UPGRADE
//
// Example of custom Bezier tessellation smoothing on quad topology.
// 
// Requirements : non split normals, quads only, and uv aligned with quad grid for "FollowTB" mode.
//
// Problem : PN tessellation is not smooth on edges, so the TBN does not match and tearing can occur if we use it for displacement.
// PN tessellation : https://www.cise.ufl.edu/research/SurfLab/papers/1008PNquad.pdf, or see PN_Quad shader for my cheaper variant.
//
// Solution : build my own smooth bezier patch, while making sure that it is C2 on edges.
// Strategy : for each edge (P0, b01, b10, P1), ensure b01-P0 is on plane tangent to (P0, n0).
// Also make sure that formulas for P(uv), dP(uv) are only dependent on edge values along the edge.
//
// Like for PN_Quad, we start looking at the edge P0P1 with normals n0 n1, and t barycentric coordinate (t=0 -> p0, t=1 -> p1)
// p0 ------- p1 -> t
//  \         /
//  n0       n1
//
// Bezier curve P(t) = P0 (1-t)^3 + 3 b01 (1-t)^2 t + 3 b10 (1-t) t^2 + t^3 P1.
// 2 variants for b_ij :
// - b01 = P0 + length(P0 - P1) / 3 * normalized(P1 - P0 - dot(P1 - P0, n0) n0) : one third the edge, towards P1, made normal to n0 but still in the (n0,edge) plane. Patch looks clipped at quad edge.
// - b01 = P0 + length(P0 - P1) / 3 * (is edge on u ? tangent : binormal) * orientation. Lock to TBN and will distort to follow its rotation around normal.
// Using one third makes control points equally spaced and thus tessellation spacing too.
// The second variant (locked to TBN) is chosen to enable C1 on edges, by having displacement vectors colinear around the vertex.
//
// Instead of building a real bezier surface patch P(u, v) = sum_{0 <= i,j <= 3} b_ij C(i, 3) (1-u)^(3-i) u^i C(j, 3) (1-v)^(3-j) v^j,
// we will use the same trick as my PN_Quad variant : expressing the displacement from linear uv interpolation, and combining displacements lerped on each side.
// On the 01 edge, using D01 = b01-P0 and D10 = b10-P1 :
// Linear interpolation : I(t) = (1 - t) P0 + t P1.
// Displacement D(t) = P(t)-I(t) = (1-t)t [(1-t) D01 + t D10 + (2t - 1) (P1 - P0)]
// This only adds a component to PN_Quad D(t) = (1-t)t [(1-t) D01 + t D10]
//
// Using these displacements, it is easy to combine both axis of the patch :
// P(u, v) = I(u, v) + lerp(v, P01(u), P23(u)) + lerp(u, P03(v), P12(v));
// 
// TBN can be computed by deriving P(u, v) by u and v.
// This is not C1 on edges.
// The trick to make it C1 is to :
// - generate displacements vectors that are colinear around vertex, using the TBN
// - use the tangent/binormal in line with edge ; it only depends on edge vertex data (+TBN)
// - near the edge, use simple linear interpolation for the other tangent/binormal, then cross for normal. This works surprisingly well.

// Useful links :
// Tessellation introduction https://nedmakesgames.medium.com/mastering-tessellation-shaders-and-their-many-uses-in-unity-9caeb760150e
// Tessellation factor semantics, useful for quads : https://www.reedbeta.com/blog/tess-quick-ref/
// Projection matrices https://jsantell.com/3d-projection/
// Archived reference https://microsoft.github.io/DirectX-Specs/d3d/archive/D3D11_3_FunctionalSpec.htm#HullShader
// Good practices from nvidia https://developer.download.nvidia.com/whitepapers/2010/PN-AEN-Triangles-Whitepaper.pdf

Shader "Lereldarion/Bezier_Quad" {
    Properties {
        [Toggle(TBN)] _Mode_TBN ("Show TBN instead of surface", Float) = 0
        _Tessellation ("Tessellation", Integer) = 1
    }
    SubShader {
        Tags {
            "RenderType" = "Opaque"
            "VRCFallback" = "Standard"
        }

        Pass {
            Tags { "LightMode" = "ForwardBase" }

            Cull Off

            CGPROGRAM
            #pragma target 5.0
            #pragma multi_compile_instancing
            #pragma multi_compile_fwdbase nolightmap nodirlightmap nodynlightmap novertexlight // compile shader into multiple variants, with and without shadows (skip lightmap variants)

            #pragma vertex true_vertex_stage
            #pragma hull hull_control_point_stage
            #pragma domain domain_stage
            #pragma geometry geometry_stage
            #pragma fragment fragment_stage

            #include "UnityCG.cginc"
            #include "UnityLightingCommon.cginc"
            #include "AutoLight.cginc" // shadow helper functions and macros

            ///////////////////////////////////////////////////////////////////
            // Normal vertex and fragment, that will be used within tessellation later

            struct VertexData {
                float3 position_os : POSITION_OS;
                float3 normal_os : NORMAL_OS;
                float3 tangent_os : TANGENT_OS;
                float3 binormal_os : BINORMAL_OS;
                float2 uv0 : TEXCOORD0;
                float3 other : OTHER;
                UNITY_VERTEX_INPUT_INSTANCE_ID // Setup has been called
            };

            ///////////////////////////////////////////////////////////////////

            struct TrueVertexData {
                float3 position_os : POSITION;
                // May be non-normalized due to skinning
                float3 normal_os : NORMAL;
                float4 tangent_os : TANGENT;

                float2 uv0 : TEXCOORD0; // Used to guide ruffles : X = direction along ruffles 01, Y = from flat to thick on a ruffle 01.                
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct TessellationVertexData {
                float3 position_os : POSITION_OS;
                // Normalized
                float3 normal_os : NORMAL_OS;
                float3 tangent_os : TANGENT_OS;
                float3 binormal_os : BINORMAL_OS;
                float normal_scale : VERTEX_SCALE;
                
                float2 uv0 : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct TessellationControlPoint {
                TessellationVertexData vertex;

                // Bezier displacement vectors from this vertex
                float3 d_edge_u : D_EDGE_U;
                float3 d_edge_v : D_EDGE_V;
            };

            struct TessellationFactors {
                // Subdivision factors related to patch_uv
                float edge[4] : SV_TessFactor; // Subdivide along edges [u=0, v=0, u=1, v=1]
                float inside[2] : SV_InsideTessFactor; // Subdivide interior along axis [u, v] ; 0 = e1/e3, 1 = e0/e2

                // Vertex patch_uv association is chosen as [(0, 0), (1, 0), (1, 1), (0, 1)]
                // v             e3
                // ↑  b3  -- b32 -- b23 -- b2
                //    b30 ---------------- b21 e2
                // e0 b03 ---------------- b12
                //    b0  -- b01 -- b10 -- b1
                //               e1            -> u
            };

            // Constants

            uniform uint _Tessellation;

            void true_vertex_stage (const TrueVertexData input, out TessellationVertexData output) {
                UNITY_SETUP_INSTANCE_ID (input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);

                output.position_os = input.position_os.xyz;
                output.normal_scale = length(input.normal_os); // Length useful to adjust ruffle thickness with skinning+scaling
                output.normal_os = input.normal_os / output.normal_scale; // Might as well with the length
                output.tangent_os = normalize(input.tangent_os.xyz);
                output.binormal_os = normalize(cross(output.normal_os, output.tangent_os)) * input.tangent_os.w;

                output.uv0 = input.uv0;
            }

            uint rotation_to_align_patch_with_uv(const InputPatch<TessellationVertexData, 4> inputs, uint id) {
                // Rotate patch to ensure uv and patch_uv are aligned.
                // Align uv.y positive slope with patch_uv +Y.
                float2 current_patch_delta_y = float2(
                    (inputs[1].uv0.y + inputs[2].uv0.y) - (inputs[0].uv0.y + inputs[3].uv0.y), // u
                    (inputs[2].uv0.y + inputs[3].uv0.y) - (inputs[0].uv0.y + inputs[1].uv0.y)  // v
                );
                // 4 rotations depending on ruffle_uv.y slope orientation
                [flatten]
                if (abs(current_patch_delta_y.y) >= abs(current_patch_delta_y.x)) {
                    if (current_patch_delta_y.y >= 0) {
                        return 0; // Slope is +Y
                    } else {
                        return 2; // Slope is -Y, rotate 180
                    }
                } else {
                    if (current_patch_delta_y.x >= 0) {
                        return 3; // Slope is +X, rotate 270 to return b3 as b0
                    } else {
                        return 1; // Slope is -X, rotate 90 to return b1 as b0
                    }
                }
            }

            [domain ("quad")]
            [outputcontrolpoints (4)]
            [outputtopology ("triangle_cw")]
            [patchconstantfunc ("hull_patch_constant_stage")]
            [partitioning ("integer")]
            //[maxtessfactor (64.)]
            TessellationControlPoint hull_control_point_stage (const InputPatch<TessellationVertexData, 4> inputs, uint id : SV_OutputControlPointID) {
                uint rotation = rotation_to_align_patch_with_uv(inputs, id);
                id = (id + rotation) % 4;
                
                TessellationControlPoint output;
                
                const TessellationVertexData input = inputs[id];
                UNITY_SETUP_INSTANCE_ID (input);
                output.vertex = input;
                
                bool swaps_axis = rotation & 1 == 1;
                TessellationVertexData input_u = inputs[id ^ (swaps_axis ? 3 : 1)];
                TessellationVertexData input_v = inputs[id ^ (swaps_axis ? 1 : 3)];

                output.d_edge_u = length(input_u.position_os - input.position_os) * sign(input_u.uv0.x - input.uv0.x) * input.tangent_os;
                output.d_edge_v = length(input_v.position_os - input.position_os) * sign(input_v.uv0.y - input.uv0.y) * input.binormal_os * unity_WorldTransformParams.w;
                return output;
            }

            void hull_patch_constant_stage (const OutputPatch<TessellationControlPoint, 4> cp, out TessellationFactors factors) {                
                factors.inside[0] = factors.edge[1] = factors.edge[3] = _Tessellation;
                factors.inside[1] = factors.edge[0] = factors.edge[2] = _Tessellation;
            }

            struct InterpolatedVertexData {
                float3 position;
                float3 tangent;
                float3 binormal;
                float3 normal;
                float2 uv0;

                float3 other;

                static InterpolatedVertexData interpolate(const OutputPatch<TessellationControlPoint, 4> cp, float2 patch_uv) {
                    float4 muv_uv = float4 (1.0 - patch_uv, patch_uv);
                    float2 umu_vmv = muv_uv.xy * muv_uv.zw;
                    float4 linear_factors = muv_uv.xzzx * muv_uv.yyww;
                    float2 edge_factors = umu_vmv * (2.0 * patch_uv - 1.0);

                    float4 dlinear_factors_dx = float4(-1, 1, 1, -1) * muv_uv.yyww;
                    float4 dlinear_factors_dy = muv_uv.xzzx * float4(-1, -1, 1, 1);

                    float2 dt2mt = (-3.0 * patch_uv + 2.0) * patch_uv; // (du2mu_du, dv2mv_dv)
                    float2 dmt2t = (3.0 * patch_uv - 4.0) * patch_uv + 1.0; // (dmu2u_du, dmv2v_dv)
                    float2 dedge_factors = (-6.0 * patch_uv + 6.0) * patch_uv - 1.0;

                    InterpolatedVertexData output;

                    float4x3 cp_positions = float4x3(cp[0].vertex.position_os, cp[1].vertex.position_os, cp[2].vertex.position_os, cp[3].vertex.position_os);
                    float4x3 cp_d_edge_u = float4x3(cp[0].d_edge_u, cp[1].d_edge_u, cp[2].d_edge_u, cp[3].d_edge_u);
                    float4x3 cp_d_edge_v = float4x3(cp[0].d_edge_v, cp[1].d_edge_v, cp[2].d_edge_v, cp[3].d_edge_v);
                    float4x3 edges = float4x3(cp_positions[3] - cp_positions[0], cp_positions[1] - cp_positions[0], cp_positions[2] - cp_positions[1], cp_positions[2] - cp_positions[3]);

                    output.position = (
                        mul(linear_factors, cp_positions) +
                        umu_vmv.x * mul(linear_factors, cp_d_edge_u) +
                        umu_vmv.y * mul(linear_factors, cp_d_edge_v) +
                        mul(muv_uv * edge_factors.yxyx, edges)
                    );

                    // Derivatives give us a proper tangent+binormal, except on the edge where they are not continuous with other patches.
                    float3 dposition_dx = (
                        mul(dlinear_factors_dx, cp_positions) +
                        mul(float4(dmt2t.x, dt2mt.x, dt2mt.x, dmt2t.x) * muv_uv.yyww, cp_d_edge_u) +
                        umu_vmv.y * mul(dlinear_factors_dx, cp_d_edge_v) +
                        mul(float4(-edge_factors.y, muv_uv.y * dedge_factors.x, edge_factors.y, muv_uv.w * dedge_factors.x), edges)
                    );
                    float3 dposition_dy = (
                        mul(dlinear_factors_dy, cp_positions) +
                        umu_vmv.x * mul(dlinear_factors_dy, cp_d_edge_u) +
                        mul(muv_uv.xzzx * float4(dmt2t.y, dmt2t.y , dt2mt.y, dt2mt.y), cp_d_edge_v) +
                        mul(float4(muv_uv.x * dedge_factors.y, -edge_factors.x, muv_uv.z * dedge_factors.y, edge_factors.x), edges)
                    );
                    float3 tangent_dir = dposition_dx * sign(cp[1].vertex.uv0.x - cp[0].vertex.uv0.x);
                    float3 binormal_dir = dposition_dy * sign(cp[3].vertex.uv0.y - cp[0].vertex.uv0.y) * unity_WorldTransformParams.w;

                    // On the edges, the tangent/binormal in line with the edge is ok. But the other is not, so use a linear interpolation.
                    float2 distance_to_edges = 0.5 - abs(patch_uv - 0.5);
                    float distance_threshold = 0.01;
                    float2 edge_approximation_lerp = distance_to_edges / distance_threshold; // 0 at edge, 1 at threshold, more inside
                    if(edge_approximation_lerp.x < 1) {
                        float3 interpolated = mul(linear_factors, float4x3(cp[0].vertex.tangent_os, cp[1].vertex.tangent_os, cp[2].vertex.tangent_os, cp[3].vertex.tangent_os));
                        tangent_dir = lerp(interpolated, tangent_dir, edge_approximation_lerp.x);
                    }
                    if(edge_approximation_lerp.y < 1) {
                        float3 interpolated = mul(linear_factors, float4x3(cp[0].vertex.binormal_os, cp[1].vertex.binormal_os, cp[2].vertex.binormal_os, cp[3].vertex.binormal_os));
                        binormal_dir = lerp(interpolated, binormal_dir, edge_approximation_lerp.y);
                    }

                    // Finalize TBN
                    output.tangent = normalize(tangent_dir);
                    output.binormal = normalize(binormal_dir);
                    output.normal = normalize(cross(output.binormal, output.tangent)); 

                    output.other = normalize(mul(linear_factors, float4x3(cp[0].vertex.binormal_os, cp[1].vertex.binormal_os, cp[2].vertex.binormal_os, cp[3].vertex.binormal_os)));

                    output.uv0 = mul(linear_factors, float4x2(cp[0].vertex.uv0, cp[1].vertex.uv0, cp[2].vertex.uv0, cp[3].vertex.uv0));

                    return output;
                }
            };

            [domain ("quad")]
            void domain_stage (const TessellationFactors factors, const OutputPatch<TessellationControlPoint, 4> cp, float2 patch_uv : SV_DomainLocation, out VertexData output) {
                UNITY_SETUP_INSTANCE_ID (cp[0].vertex);
                UNITY_TRANSFER_INSTANCE_ID(cp[0].vertex, output);
                
                InterpolatedVertexData pn = InterpolatedVertexData::interpolate(cp, patch_uv);

                output.position_os = pn.position;
                output.normal_os = pn.normal;
                output.tangent_os = pn.tangent;
                output.binormal_os = pn.binormal;
                output.other = pn.other;
                output.uv0 = pn.uv0;
            }

            /////// TBN debug

            struct FragmentInput {
                float4 position : SV_POSITION; // CS as rasterizer input, screenspace as fragment input
                float3 color : EDGE_COLOR;
                UNITY_VERTEX_OUTPUT_STEREO
            };
            
            void draw_vector(inout LineStream<FragmentInput> stream, float3 origin, float3 direction, float3 color) {
                FragmentInput output;
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
                output.color = color;

                output.position = UnityObjectToClipPos(origin);
                stream.Append(output);
                
                output.position = UnityObjectToClipPos(origin + direction);
                stream.Append(output);

                stream.RestartStrip();
            }
            void draw_tbn(inout LineStream<FragmentInput> stream, VertexData input, float length) {
                draw_vector(stream, input.position_os, input.tangent_os * length, float3(1, 0, 0));
                draw_vector(stream, input.position_os, input.binormal_os * length, float3(0, 1, 0));
                draw_vector(stream, input.position_os, input.normal_os * length, float3(0, 0, 1));
                draw_vector(stream, input.position_os, input.other * length, float3(1, 1, 0));
            }

            float length_sq(float3 v) {
                return dot(v, v);
            }

            #pragma shader_feature_local TBN
            #if TBN
            [maxvertexcount(18)]
            void geometry_stage(triangle VertexData input[3], uint triangle_id : SV_PrimitiveID, inout LineStream<FragmentInput> stream) {
                UNITY_SETUP_INSTANCE_ID(input[0]);

                float length = sqrt(min(
                    length_sq(input[0].position_os - input[1].position_os),
                    min(
                        length_sq(input[0].position_os - input[2].position_os),
                        length_sq(input[1].position_os - input[2].position_os)
                    )
                ));
                float display_length = 0.7 * length;
                draw_tbn(stream, input[0], display_length);
                draw_tbn(stream, input[1], display_length);
                draw_tbn(stream, input[2], display_length);
            }
            #else // Triangle
            [maxvertexcount(3)]
            void geometry_stage(triangle VertexData input[3], uint triangle_id : SV_PrimitiveID, inout TriangleStream<FragmentInput> stream) {
                UNITY_SETUP_INSTANCE_ID(input[0]);
                FragmentInput output;
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
                output.color = float3(1, 1, 1);

                output.position = UnityObjectToClipPos(input[0].position_os);
                output.color = float3(input[0].uv0, 0);
                stream.Append(output);

                output.position = UnityObjectToClipPos(input[1].position_os);
                output.color = float3(input[1].uv0, 0);
                stream.Append(output);

                output.position = UnityObjectToClipPos(input[2].position_os);
                output.color = float3(input[2].uv0, 0);
                stream.Append(output);
            }
            #endif

            fixed4 fragment_stage (FragmentInput input) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                return fixed4(input.color, 1);
            }

            ENDCG
        }
    }
}
