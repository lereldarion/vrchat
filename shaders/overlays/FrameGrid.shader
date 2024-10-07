// An overlay which displays 3d grid lines over the environnement
// Zoom controls the grid scale
// Added cutoff
// Failed to add fullscreen mode. Proper WS is required here, but it cannot be rebuilt from CS alone (fullscreen case) due to lacking inv_P (https://gist.github.com/bgolus/a07ed65602c009d5e2f753826e8078a0). 

Shader "Lereldarion/Overlay/FrameGrid" {
    Properties {
        _Grid_Zoom("Grid Zoom", Float) = 1
    }
    SubShader {
        Tags {
            "Queue" = "Overlay"
            "RenderType" = "Overlay"
            "VRCFallback" = "Hidden"
            "PreviewType" = "Plane"
        }
        
        Cull Off
        Blend One One
        ZWrite Off
        ZTest Less

        Pass {
            CGPROGRAM
            #pragma vertex vertex_stage
            #pragma fragment fragment_stage
            #pragma multi_compile_instancing
            
            #include "UnityCG.cginc"
            #pragma target 5.0

            struct VertexInput {
                float4 position_os : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct FragmentInput {
                float4 position_cs : SV_POSITION;
                float4 raw_position_cs : RAW_POSITION_CS; // untouched by POSITION semantics
                float3 eye_to_geometry_ws : EYE_TO_GEOMETRY_WS;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            void vertex_stage (VertexInput input, out FragmentInput output) {
                UNITY_SETUP_INSTANCE_ID(input);
                output.position_cs = UnityObjectToClipPos(input.position_os);
                output.raw_position_cs = output.position_cs;
                output.eye_to_geometry_ws = mul(unity_ObjectToWorld, input.position_os).xyz - _WorldSpaceCameraPos.xyz;
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
            }

            UNITY_DECLARE_DEPTH_TEXTURE(_CameraDepthTexture);

            float3 scene_world_position_at(float4 position_cs, float3 eye_to_geometry_ws) {
                // Calculate screen UV ; here we have a legit CS position so we can use unity macros to handle the SPS-I/non SPS-I differences
                float4 screen_pos = ComputeScreenPos(position_cs);
                float2 screen_uv = screen_pos.xy / screen_pos.w;
                // Read depth, linearizing into view space z depth
                float depth_texture_value = SAMPLE_DEPTH_TEXTURE_LOD(_CameraDepthTexture, float4(screen_uv, 0, 0));
                if (!(0 < depth_texture_value && depth_texture_value < 1)) {
                    // Undefined depth values : prevent graphical noise, discard pixel (equivalent to 0 emission)
                    discard;
                }
                float linear_depth = LinearEyeDepth(depth_texture_value);
                // Reconstruct world space of displaced pixel, but replace its w-depth by the sampled one
                return _WorldSpaceCameraPos.xyz + eye_to_geometry_ws * linear_depth / position_cs.w;
            }
            
            float3 distance_to_01_grid_lines(float3 position) {
                return abs(frac(0.5 + position) - 0.5);
            }
            
            uniform float _Grid_Zoom;

            fixed4 fragment_stage (FragmentInput i) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                // Idea : add tint if position is close to axis xyz at grid_size intervals
                float3 scene_world_position = scene_world_position_at(i.raw_position_cs, i.eye_to_geometry_ws);
                // distance to grid [0, 0.5]
                float3 grid_distance = distance_to_01_grid_lines(_Grid_Zoom * scene_world_position);
                // non-linearize to spike if distance is 0
                float3 grid_proximity = saturate(0.5 - grid_distance * grid_distance * 1000);
                // Already fits Blender colors : x=red, y=green, z=blue
                return float4(grid_proximity, 1);
            }

            ENDCG
        }
    }
}
