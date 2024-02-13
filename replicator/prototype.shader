// UNITY_SHADER_NO_UPGRADE

Shader "Lereldarion/Replicator/Prototype"
{
    // Idea : expand each triangle to a replicator block geometry.
    // Use the triangle as a local reference frame to orient the geometry.
    // Do not support local non-uniform scale, as we have no data on the z axis.
    //
    // Use a LOD threshold ; if too far just draw the flat triangle.
    // To that end the triangle is designed to cover the flattened block geometry, and we can draw an alpha texture in cutout mode.
    // Draw it two times to be double sided.
    //
    // 3rd mode : fallback using the flat LOD with a doublesided cutout

    Properties
    {
        _Replicator_Lod_World_Distance("Worldspace distance of LOD threshold", Float) = 10
        _Replicator_Dislocation_Animation_Time("Dislocation animation time", float) = 0
    }
    SubShader
    {
        Tags {
			"RenderType" = "Opaque"
			"VRCFallback" = "ToonCutoutDoubleSided"
		}
		
        Pass
        {
            Tags {
                "LightMode" = "ForwardBase"
            }

            CGPROGRAM
            #pragma target 5.0
            #pragma vertex vertex_stage
            #pragma geometry geometry_stage
            #pragma fragment fragment_stage
			#pragma multi_compile_instancing
            #include "UnityCG.cginc"

            struct VertexInput {
                float4 position_os : POSITION;
                float3 normal_os : NORMAL;
                float4 tangent_os : TANGENT;
                float2 uv : TEXCOORD0;
				UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Vertex2Geometry {
                float4 position_os : POSITION_OS;
                float3 normal_os : NORMAL;
                float4 tangent_os : TANGENT;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            struct Geometry2Fragment {
                float4 position_cs : SV_POSITION;
                float3 normal_ws : NORMAL;
                float3 tangent_ws : TANGENT;
                float2 uv : TEXCOORD0;

                UNITY_VERTEX_OUTPUT_STEREO
            };

            Vertex2Geometry vertex_stage (VertexInput input) {
                Vertex2Geometry output;
				UNITY_SETUP_INSTANCE_ID(input);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
                output.position_os = input.position_os;
                output.normal_os = input.normal_os;
                output.tangent_os = input.tangent_os;
                output.uv = input.uv;                
                return output;
            }

            uniform float _Replicator_Lod_World_Distance; // FIXME use object scale (still uniform)

            float length_squared(float3 v) { return dot(v, v); }
            float distance_squared(float3 lhs, float3 rhs) { return length_squared(rhs - lhs); }

            uint lod_level() {
                #if UNITY_SINGLE_PASS_STEREO
                float3 camera_position_ws = 0.5 * (unity_StereoWorldSpaceCameraPos[0] + unity_StereoWorldSpaceCameraPos[1]);
                #else
                float3 camera_position_ws = _WorldSpaceCameraPos;
                #endif
                float3 camera_position_os = mul(unity_WorldToObject, float4(camera_position_ws, 1)).xyz;
                float camera_distance_squared_os = length_squared(camera_position_os);

                // Never animated, and 5m works well ; account for avatar scaling
                // Using pixel precision would be better, but this works ok for now
                float2 lod_transitions = float2(5, 10);
                float2 lod_transitions_sq = lod_transitions * lod_transitions;
                uint2 use_upper_lod = camera_distance_squared_os < lod_transitions_sq ? 0 : 1;
                return use_upper_lod[0] + use_upper_lod[1]; // 0 -> 1 -> 2
            }

            float4x4 ts_to_os_from_triangle_tangent_space(Vertex2Geometry input[3]) {
                // For simplicity use normal and tangent vector as base, and triangle barycenter as origin (3-way symmetric).
                // Scale them by a linear 3-way symmetric measure that follows scale. Does not support non-uniform scaling by averaging, but should be avoided.
                // Cons : requires precise Unity incantations for tangent space. Non-uniform scaling rotates the block.
                float3 ts_origin_os = (input[0].position_os.xyz + input[1].position_os.xyz + input[2].position_os.xyz) / 3.;
                float scale = sqrt(distance_squared(input[0].position_os.xyz, input[1].position_os.xyz) + distance_squared(input[0].position_os.xyz, input[2].position_os.xyz) + distance_squared(input[1].position_os.xyz, input[2].position_os.xyz));
                // Orientation is chosen to match the one in blender (convenience)
                float flip_binormal = input[0].tangent_os.w * unity_WorldTransformParams.w; // https://forum.unity.com/threads/what-is-tangent-w-how-to-know-whether-its-1-or-1-tangent-w-vs-unity_worldtransformparams-w.468395/
                float3 ts_z_os = input[0].normal_os.xyz * scale * -input[0].tangent_os.w; // we want to deduce the normal from uv orientation instead of using face normal (half are bad due to mirror) ; this factor seems to work
                float3 ts_y_os = input[0].tangent_os.xyz * scale;
                float3 ts_x_os = cross(input[0].tangent_os.xyz, input[0].normal_os.xyz) * input[0].tangent_os.w * scale;
                // Matrix transformation
                float4x4 ts_to_os = 0;
                ts_to_os._m00_m10_m20 = ts_x_os;
                ts_to_os._m01_m11_m21 = ts_y_os;
                ts_to_os._m02_m12_m22 = ts_z_os;
                ts_to_os._m03_m13_m23_m33 = float4(ts_origin_os, 1);
                return ts_to_os;
            }

            float4x4 ts_to_os_from_triangle_position_manual(Vertex2Geometry input[3]) {
                // Manually define a reference frame : xy on triangle plane, +x towards symmetric corner, origin on barycenter.
                // Scale them by the length of the small side (assymmetric) ; should allow elongation by "sliding" on chains of blocks.
                // Cons : we only need positions, but they must be sorted by uv to identify them.
                float3 ts_origin_os = (input[0].position_os.xyz + input[1].position_os.xyz + input[2].position_os.xyz) / 3.;
                // Sort positions by uv
                float3 bottom;
                float3 left;
                float3 top_right;
                UNITY_UNROLL
                for(int i = 0; i < 3; i += 1) {
                    UNITY_FLATTEN
                    if (input[i].uv.y > 0.8) { top_right = input[i].position_os; }
                    else if (input[i].uv.y < 0.2) { bottom = input[i].position_os; }
                    else { left = input[i].position_os; }
                }
                // Build basis vectors
                float3 ts_y_os = left - bottom;
                float3 normalized_x = normalize(top_right - ts_origin_os);
                float3 ts_x_os = normalized_x * length(ts_y_os);
                float3 ts_z_os = cross(normalized_x, ts_y_os) * -unity_WorldTransformParams.w; // Handle negative scaling
                // Matrix transformation
                float4x4 ts_to_os = 0;
                ts_to_os._m00_m10_m20 = ts_x_os;
                ts_to_os._m01_m11_m21 = ts_y_os;
                ts_to_os._m02_m12_m22 = ts_z_os;
                ts_to_os._m03_m13_m23_m33 = float4(ts_origin_os, 1);
                return ts_to_os;
            }

            float3x3 rotation_matrix(float3 axis, float angle_radians) {
                // https://en.wikipedia.org/wiki/Rotation_matrix#Rotation_matrix_from_axis_and_angle
                float3 u = normalize(axis);
                float C = cos(angle_radians);
                float S = sin(angle_radians);
                float t = 1 - C;
                float m00 = t * u.x * u.x + C;
                float m01 = t * u.x * u.y - S * u.z;
                float m02 = t * u.x * u.z + S * u.y;
                float m10 = t * u.x * u.y + S * u.z;
                float m11 = t * u.y * u.y + C;
                float m12 = t * u.y * u.z - S * u.x;
                float m20 = t * u.x * u.z - S * u.y;
                float m21 = t * u.y * u.z + S * u.x;
                float m22 = t * u.z * u.z + C;
                return float3x3(m00, m01, m02, m10, m11, m12, m20, m21, m22);
            }

            // float4(xyz = translation speed (m/s WS) + rotation axis (TS), w = rotation speed in rad/s)
            static const uint dislocation_animation_table_size = 4; // Preferably use a power of 2 for cheap modulo
            static const float4 dislocation_animation_table[dislocation_animation_table_size] = {
                float4(0, 3.5, 1, 1),
                float4(1, -1, 0, 0.4),
                float4(1, 1, 1, 1.5),
                float4(0, 0, -3, 0.1),
            };

            uniform float _Replicator_Dislocation_Animation_Time;

            void animate_ts_to_ws(inout float4x4 ts_to_ws, uint id) {
                float t = _Replicator_Dislocation_Animation_Time;
                // Pick a vector ; we just need some variety of animations between blocks so the precise link between translation and rotation does not matter.
                float4 animation_data = dislocation_animation_table[id % dislocation_animation_table_size];
                // Add more variety by reusing the vector with swapped axis ; again use mod 2^n
                float3 xyz;
                UNITY_FLATTEN switch((id / dislocation_animation_table_size) % 4) {
                    case 0: xyz = animation_data.xyz; break;
                    case 1: xyz = animation_data.yzx; break;
                    case 2: xyz = animation_data.zxy; break;
                    case 3: xyz = animation_data.xzy; break;
                }
                // Rotate triangle space (as values are centered on 0, and rotation operates with an axis on 0 too).
                // This does not touch translation nor w scale;
                float3x3 new_ts_to_ws_rot = mul((float3x3) ts_to_ws, rotation_matrix(xyz, t * animation_data.w * (2 * 3.14)));
                for(int i = 0; i < 3; i += 1) {
                    ts_to_ws[i].xyz = new_ts_to_ws_rot[i];
                }
                // Fall translation
                const float3 gravity = float3(0, -9.81, 0); // Unity has Y for vertical
                ts_to_ws._m03_m13_m23 += xyz * t + 0.5 * gravity * t * t;
            }

            #include "baked_geometry_data.hlsl"

            [instance(nb_geometry_instances)]
            [maxvertexcount(nb_vertices_per_geometry_instance)]
            void geometry_stage (triangle Vertex2Geometry input[3], uint block_id : SV_PrimitiveID, uint instance_id : SV_GSInstanceID, inout TriangleStream<Geometry2Fragment> stream) {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input[0]);

                // Generate 3d geometry, using the triangle as a reference frame (after skinning)
                float4x4 ts_to_ws = mul(unity_ObjectToWorld, ts_to_os_from_triangle_position_manual(input)); // To rotate normals. As MVP is not precomputed, 2 matrix multiply are needed anyway.
                animate_ts_to_ws(ts_to_ws, block_id); // TODO feature disable ?
                float4x4 ts_to_cs = mul(UNITY_MATRIX_VP, ts_to_ws); // For projecting points.


                uint lod_offset = lod_level() * nb_geometry_instances;
                uint start = geometry_instance_boundaries[instance_id + lod_offset];
                uint end = geometry_instance_boundaries[instance_id + lod_offset + 1];
                for (uint i = start; i < end; i += 1) {
                    BakedVertexData baked = geometry_baked_vertex_data[i];
                    if (baked.strip_restart) {
                        stream.RestartStrip();
                    }
                    Geometry2Fragment output;
                    UNITY_TRANSFER_VERTEX_OUTPUT_STEREO(input[0], output);
                    output.position_cs = mul(ts_to_cs, float4(baked.position_ts, 1.));
                    output.normal_ws = normalize(mul((float3x3) ts_to_ws, baked.normal_ts));
                    output.tangent_ws = normalize(mul((float3x3) ts_to_ws, baked.tangent_ts));
                    output.uv = baked.uv0;
                    stream.Append(output);
                }
            }

            fixed4 fragment_stage (Geometry2Fragment i) : SV_Target {
				UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                float3 normal_vs = normalize (mul((float3x3) UNITY_MATRIX_V, i.normal_ws));
                //return fixed4(abs(normal_vs).zzz, 1);
                return fixed4(normal_vs * 0.5 + 0.5, 1);
            }
            ENDCG
        }
    }
}