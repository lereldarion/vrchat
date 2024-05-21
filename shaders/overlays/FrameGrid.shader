// An overlay which displays 3d grid lines over the environnement
// Zoom controls the grid scale

Shader "Lereldarion/Overlay/FrameGrid" {
    Properties {
        _Grid_Zoom("Grid Zoom", Float) = 1
    }
    SubShader {
        Tags {
            "Queue" = "Overlay"
            "RenderType" = "Overlay"
            "VRCFallback" = "Hidden"
        }
        
        Cull Off
        Blend One One
        ZWrite Off

        Pass {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            
            #include "UnityCG.cginc"
            #pragma target 5.0

            struct appdata {
                float4 position_os : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct v2f {
                float4 position_cs : SV_POSITION;
                float4 raw_position_cs : TEXCOORD0; // untouched by POSITION semantics
                float3 eye_to_geometry_ws : TEXCOORD1;

                UNITY_VERTEX_OUTPUT_STEREO
            };

            // Macro required: https://issuetracker.unity3d.com/issues/gearvr-singlepassstereo-image-effects-are-not-rendering-properly
            // Requires a source of dynamic light to be populated https://github.com/netri/Neitri-Unity-Shaders#types ; sad...
            UNITY_DECLARE_DEPTH_TEXTURE(_CameraDepthTexture);

            uniform float _Grid_Zoom;

            v2f vert (appdata i) {
                UNITY_SETUP_INSTANCE_ID(i);
                v2f o;
                o.raw_position_cs = UnityObjectToClipPos(i.position_os);
                o.position_cs = o.raw_position_cs;
                o.eye_to_geometry_ws = mul(unity_ObjectToWorld, i.position_os).xyz - _WorldSpaceCameraPos.xyz;
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                return o;
            }

            float3 scene_world_position_at(float4 position_cs, float3 eye_to_geometry_ws) {
                // Calculate screen UV ; here we have a legit CS position so we can use unity macros to handle the SPS-I/non SPS-I differences
                float4 screen_pos = ComputeScreenPos(position_cs);
                float2 screen_uv = screen_pos.xy / screen_pos.w;
                // Read depth, linearizing into view space z depth
                float depth_texture_value = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, screen_uv);
                if (depth_texture_value == 0) {
                    // Undefined depth values : prevent graphical noise by returning world position that generates no highlight.
                    // We highlight on integer grid coordinates, so 0.5 is the most distant point from that (modulo 1 in x,y,z).
                    return _Grid_Zoom * 0.5;
                }
                float linear_depth = LinearEyeDepth(depth_texture_value);
                // Reconstruct world space of displaced pixel, but replace its w-depth by the sampled one
                return _WorldSpaceCameraPos.xyz + eye_to_geometry_ws * linear_depth / position_cs.w;
            }

            float3 distance_to_01_grid_lines(float3 position) {
                return abs(frac(0.5 + position) - 0.5);
            }

            fixed4 frag (v2f i) : SV_Target {
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
