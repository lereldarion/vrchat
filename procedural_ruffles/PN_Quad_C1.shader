// UNITY_SHADER_NO_UPGRADE
//
// Example of PN tessellation smoothing on quad topology.
// https://www.cise.ufl.edu/research/SurfLab/papers/1008PNquad.pdf
//
// Requirements : non split normals, quads only
//
// PN original version patch is a 3rd degree bezier patch : P(u, v) = sum_{0 <= i,j <= 3} b_ij C(i, 3) (1-u)^(3-i) u^i C(j, 3) (1-v)^(3-j) v^j
// With b_ij = Pi + 1/3 ((Pj - Pi) - dot (Pj - Pi, ni) ni) on edges, and 4 internal b_ij with another annoying formula.
//
// Edge P0P1 with normals n0 n1, and t barycentric coordinate (t=0 -> p0, t=1 -> p1)
// p0 ------- p1 -> t
//  \         /
//  n0       n1
// On the 01 edge : P(t) = P0 (1-t)^3 + 3 b01 (1-t)^2 t + 3 b10 (1-t) t^2 + t^3 P1
// Linear interpolation : I(t) = (1 - t) P0 + t P1.
// Displacement D(t) = P(t)-I(t) = (1-t)t [(1-t) dot(P0 - P1, n0) n0 + t dot(P1 - P0, n1) n1]
//              D(t) = (1-t)t [(1-t) D01 + t D10] : a very simple formula.
// As a sidenote, Phong tessellation (quadratic) is D(t) = (1-t)t [D01 + D10], very similar.
//
// Using these displacements, it is easy to combine both axis of the patch to get a "PN quad-ish" tessellation :
// P(u, v) = I(u, v) + lerp(v, P01(u), P23(u)) + lerp(u, P03(v), P12(v));
// It is different from the original PN quad, but similar, and with similar defects (like smoothed cube != sphere).
// It is cheaper and simpler to compute by removing the need for the internal nodes.
//
// TBN can be computed by deriving P(u, v) by u and v.
// A downside of both PN variants (original and lerp one) is that TBN is NOT smooth on edges ! Only on vertices.
//
// Test of using the original PN quad approximation for normals to build the TBN.
// In short : C1 on edges, but not a very good approximation, and needs to be fixed for tangent/binormal (improvised as PN does not address them).
// Also falls into DX11 shader compiler limitations on hull constant stage (IPC error)...

// Useful links :
// Tessellation introduction https://nedmakesgames.medium.com/mastering-tessellation-shaders-and-their-many-uses-in-unity-9caeb760150e
// Tessellation factor semantics, useful for quads : https://www.reedbeta.com/blog/tess-quick-ref/
// Projection matrices https://jsantell.com/3d-projection/
// Archived reference https://microsoft.github.io/DirectX-Specs/d3d/archive/D3D11_3_FunctionalSpec.htm#HullShader
// Good practices from nvidia https://developer.download.nvidia.com/whitepapers/2010/PN-AEN-Triangles-Whitepaper.pdf

Shader "Lereldarion/PN_Quad_C1" {
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
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID // Setup has been called
            };

            ///////////////////////////////////////////////////////////////////

            struct TrueVertexData {
                float3 position_os : POSITION;
                float3 normal_os : NORMAL; // Normal / tangent may be non-normalized due to skinning
                float4 tangent_os : TANGENT;

                float2 uv : TEXCOORD0; // Used to guide ruffles : X = direction along ruffles 01, Y = from flat to thick on a ruffle 01.
                // TODO secondary uv to configure thickness & loop count
                
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct TessellationVertexData {
                float3 position_os : POSITION_OS;
                float3 normal_os : NORMAL_OS; // Normalized
                float3 tangent_os : TANGENT_OS;
                float3 binormal_os : BINORMAL_OS;
                float normal_scale : VERTEX_SCALE;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct TessellationControlPoint {
                TessellationVertexData vertex;

                // Pn displacement towards edges along patch u and v
                float3 d_edge_u : DISPLACEMENT_EDGE_U; // dot(P - Pu, n) n
                float3 d_edge_v : DISPLACEMENT_EDGE_V; // dot(P - Pv, n) n

                // stores value for edge to self+1
                float3 cp_edge_normal : CP_EDGE_NORMAL;
                float3 cp_edge_tangent : CP_EDGE_TANGENT;
                float3 cp_edge_binormal : CP_EDGE_BINORMAL;

                float3 partial_cp_center_normal : PARTIAL_CP_CENTER_NORMAL;
                float3 partial_cp_center_tangent : PARTIAL_CP_CENTER_TANGENT;
                float3 partial_cp_center_binormal : PARTIAL_CP_CENTER_BINORMAL;
            };

            struct TessellationFactors {
                // Vertex patch_uv association is chosen as [(0, 0), (1, 0), (1, 1), (0, 1)]
                // v             e3
                // ↑  b3  -- b32 -- b23 -- b2
                //    b30 ---------------- b21 e2
                // e0 b03 ---------------- b12
                //    b0  -- b01 -- b10 -- b1
                //               e1            -> u
                float edge[4] : SV_TessFactor; // Subdivide along edges [u=0, v=0, u=1, v=1]
                float inside[2] : SV_InsideTessFactor; // Subdivide interior along axis [u, v] ; 0 = e1/e3, 1 = e0/e2
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
                output.binormal_os = normalize(cross(output.normal_os, output.tangent_os) * input.tangent_os.w);
                output.uv = input.uv;
            }

            uint rotation_to_align_patch_with_uv(const InputPatch<TessellationVertexData, 4> inputs, uint id) {
                // Rotate patch to ensure ruffle_uv and patch_uv are aligned.
                // Align uv.y positive slope with patch_uv +Y.
                float2 current_patch_delta_y = float2(
                    (inputs[1].uv.y + inputs[2].uv.y) - (inputs[0].uv.y + inputs[3].uv.y), // u
                    (inputs[2].uv.y + inputs[3].uv.y) - (inputs[0].uv.y + inputs[1].uv.y)  // v
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

            // Only works if the vector is mostly perpendicular to the edge
            float3 edge_quadratic_interpolation_center_cp(float3 edge, float3 v0, float3 v1) {
                float3 sum = v0 + v1; // Analog to average, but do not divide as we normalize anyway.
                return normalize(sum - 2.0 * dot(edge, sum) / dot(edge, edge) * edge);
            }

            [domain ("quad")]
            [outputcontrolpoints (4)]
            [outputtopology ("triangle_cw")]
            [patchconstantfunc ("hull_patch_constant_stage")]
            [partitioning ("integer")]
            //[maxtessfactor (64.)]
            TessellationControlPoint hull_control_point_stage (const InputPatch<TessellationVertexData, 4> inputs, uint id : SV_OutputControlPointID) {
                uint rotation = rotation_to_align_patch_with_uv(inputs, id);
                uint fetch_id = (id + rotation) % 4;
                
                TessellationControlPoint output;
                
                const TessellationVertexData input = inputs[fetch_id];
                UNITY_SETUP_INSTANCE_ID (input);
                output.vertex = input;
                
                // Displacement for edge u/v from this patch corner. Use xor to get the other point ids.
                bool swaps_axis = rotation & 1 == 1;
                output.d_edge_u = dot(input.position_os - inputs[fetch_id ^ (swaps_axis ? 3 : 1)].position_os, input.normal_os) * input.normal_os;
                output.d_edge_v = dot(input.position_os - inputs[fetch_id ^ (swaps_axis ? 1 : 3)].position_os, input.normal_os) * input.normal_os;

                const TessellationVertexData next = inputs[(fetch_id + 1) % 4];
                float3 edge = next.position_os - input.position_os;
                // Normal quadratic interpolation, C1 on edges. Not accurate to the curve !
                output.cp_edge_normal = edge_quadratic_interpolation_center_cp(edge, input.normal_os, next.normal_os);
                // Tangent and binormal interpolation : use on the vector that is perpendicular to the edge
                if(id & 1 == 1) {
                    // Edge along binormal : use strategy on tangent
                    output.cp_edge_tangent = edge_quadratic_interpolation_center_cp(edge, input.tangent_os, next.tangent_os);
                    output.cp_edge_binormal = normalize(cross(output.cp_edge_tangent, output.cp_edge_normal));
                } else {
                    // Edge along tangent : use strategy on binormal
                    output.cp_edge_binormal = edge_quadratic_interpolation_center_cp(edge, input.binormal_os, next.binormal_os);
                    output.cp_edge_tangent = normalize(cross(output.cp_edge_binormal, output.cp_edge_normal));
                }
                //output.cp_edge_tangent = edge_quadratic_interpolation_center_cp(edge, input.tangent_os, next.tangent_os);
                //output.cp_edge_binormal = edge_quadratic_interpolation_center_cp(edge, input.binormal_os, next.binormal_os);

                output.partial_cp_center_normal = output.cp_edge_normal * 2 + input.normal_os;
                output.partial_cp_center_tangent = output.cp_edge_tangent * 2 + input.tangent_os;
                output.partial_cp_center_binormal = output.cp_edge_binormal * 2 + input.binormal_os;
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
                float normal_scale;
                float2 uv;

                static InterpolatedVertexData interpolate(const TessellationFactors factors, const OutputPatch<TessellationControlPoint, 4> cp, float2 patch_uv) {
                    float4 muv_uv = float4 (1.0 - patch_uv, patch_uv);
                    float2 umu_vmv = muv_uv.xy * muv_uv.zw;
                    float4 linear_factors = muv_uv.xzzx * muv_uv.yyww;

                    InterpolatedVertexData output;

                    float4x3 cp_positions = float4x3(cp[0].vertex.position_os, cp[1].vertex.position_os, cp[2].vertex.position_os, cp[3].vertex.position_os);
                    float4x3 cp_d_edge_u = float4x3(cp[0].d_edge_u, cp[1].d_edge_u, cp[2].d_edge_u, cp[3].d_edge_u);
                    float4x3 cp_d_edge_v = float4x3(cp[0].d_edge_v, cp[1].d_edge_v, cp[2].d_edge_v, cp[3].d_edge_v);
                    output.position = (
                        mul(linear_factors, cp_positions) +
                        umu_vmv.x * mul(linear_factors, cp_d_edge_u) +
                        umu_vmv.y * mul(linear_factors, cp_d_edge_v)
                    );

                    if (false) {
                        float4 dlinear_factors_dx = float4(-1, 1, 1, -1) * muv_uv.yyww;
                        float4 dlinear_factors_dy = muv_uv.xzzx * float4(-1, -1, 1, 1);
                        float2 dt2mt = (-3.0 * patch_uv + 2.0) * patch_uv; // (du2mu_du, dv2mv_dv)
                        float2 dmt2t = (3.0 * patch_uv - 4.0) * patch_uv + 1.0; // (dmu2u_du, dmv2v_dv)
                        output.tangent = normalize(
                            mul(dlinear_factors_dx, cp_positions) +
                            mul(float4(dmt2t.x, dt2mt.x, dt2mt.x, dmt2t.x) * muv_uv.yyww, cp_d_edge_u) +
                            umu_vmv.y * mul(dlinear_factors_dx, cp_d_edge_v)
                        );
                        output.binormal = normalize(
                            mul(dlinear_factors_dy, cp_positions) +
                            umu_vmv.x * mul(dlinear_factors_dy, cp_d_edge_u) +
                            mul(muv_uv.xzzx * float4(dmt2t.y, dmt2t.y , dt2mt.y, dt2mt.y), cp_d_edge_v)
                        );
                        output.normal = normalize(cross(output.tangent, output.binormal));

                        // FIXME when approaching an edge (x/y), tangent(x/y) will be ok, tangent(y/x) and normal are not.
                        // lerp with normal on edge from quadratic interp. normal seems good. make it seamless ?
                        // tangent(y/x) can be obtained by cross.
                    } else {
                        //
                        float4 muv_uv_3 = muv_uv * muv_uv * muv_uv;
                        float3 x_factors = float3(muv_uv_3.x, 3 * umu_vmv.x, muv_uv_3.z);
                        float3 y_factors = float3(muv_uv_3.y, 3 * umu_vmv.y, muv_uv_3.w);
    
                        // Forced to compute these here ; a better place is in the hull constant fn, but crashes the HLSL compiler ("IPC exception").
                        float3 cp_center_normal = (cp[0].partial_cp_center_normal + cp[1].partial_cp_center_normal + cp[2].partial_cp_center_normal + cp[3].partial_cp_center_normal) / 12.0;
                        float3 cp_center_tangent = (cp[0].partial_cp_center_tangent + cp[1].partial_cp_center_tangent + cp[2].partial_cp_center_tangent + cp[3].partial_cp_center_tangent) / 12.0;
                        float3 cp_center_binormal = (cp[0].partial_cp_center_binormal + cp[1].partial_cp_center_binormal + cp[2].partial_cp_center_binormal + cp[3].partial_cp_center_binormal) / 12.0;
                        output.normal = normalize(
                            x_factors[0] * mul(y_factors, float3x3(cp[0].vertex.normal_os, cp[3].cp_edge_normal, cp[3].vertex.normal_os)) +
                            x_factors[1] * mul(y_factors, float3x3(cp[0].cp_edge_normal,   cp_center_normal,     cp[2].cp_edge_normal)) +
                            x_factors[2] * mul(y_factors, float3x3(cp[1].vertex.normal_os, cp[1].cp_edge_normal, cp[2].vertex.normal_os))
                        );
                        output.tangent = normalize(
                            x_factors[0] * mul(y_factors, float3x3(cp[0].vertex.tangent_os, cp[3].cp_edge_tangent, cp[3].vertex.tangent_os)) +
                            x_factors[1] * mul(y_factors, float3x3(cp[0].cp_edge_tangent,   cp_center_tangent,     cp[2].cp_edge_tangent)) +
                            x_factors[2] * mul(y_factors, float3x3(cp[1].vertex.tangent_os, cp[1].cp_edge_tangent, cp[2].vertex.tangent_os))
                        );
                        output.binormal = normalize(
                            x_factors[0] * mul(y_factors, float3x3(cp[0].vertex.binormal_os, cp[3].cp_edge_binormal, cp[3].vertex.binormal_os)) +
                            x_factors[1] * mul(y_factors, float3x3(cp[0].cp_edge_binormal,   cp_center_binormal,     cp[2].cp_edge_binormal)) +
                            x_factors[2] * mul(y_factors, float3x3(cp[1].vertex.binormal_os, cp[1].cp_edge_binormal, cp[2].vertex.binormal_os))
                        );
                    }

                    // Others : linear interpolation
                    output.normal_scale = dot(linear_factors, float4(cp[0].vertex.normal_scale, cp[1].vertex.normal_scale, cp[2].vertex.normal_scale, cp[3].vertex.normal_scale));
                    output.uv = mul(linear_factors, float4x2(cp[0].vertex.uv, cp[1].vertex.uv, cp[2].vertex.uv, cp[3].vertex.uv));
                    return output;
                }
            };

            [domain ("quad")]
            void domain_stage (const TessellationFactors factors, const OutputPatch<TessellationControlPoint, 4> cp, float2 patch_uv : SV_DomainLocation, out VertexData output) {
                UNITY_SETUP_INSTANCE_ID (cp[0].vertex);
                UNITY_TRANSFER_INSTANCE_ID(cp[0].vertex, output);
                
                InterpolatedVertexData pn = InterpolatedVertexData::interpolate(factors, cp, patch_uv);

                output.position_os = pn.position;
                output.normal_os = pn.normal;
                output.tangent_os = pn.tangent;
                output.binormal_os = pn.binormal;
                output.uv = pn.uv;
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
                output.color = 0.8 * float3(1, 1, 1);
                output.position = UnityObjectToClipPos(input[0].position_os); stream.Append(output);
                output.position = UnityObjectToClipPos(input[1].position_os); stream.Append(output);
                output.position = UnityObjectToClipPos(input[2].position_os); stream.Append(output);
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
