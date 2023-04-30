// A volumetric "space" shader adapted from shadertoy in Vrchat
// 
// Source : https://www.shadertoy.com/view/lslyRn
// Additional info by http://casual-effects.blogspot.com/2013/08/starfield-shader.html
// The shader samples a 3d fractal at multiple planes with color tint to create the starfield.
// This adaptation makes both eyes sample the same plane for a VR 3d volumetric effect.
// Sadly the brain see the planes when the head is rotated, which is not easy to fix.
// The transform between real world and fractal space needs to be improved too.

Shader "Lereldarion/VolumetricStarField"
{
    Properties
    {
    }
    SubShader
    {
        Tags {
			"RenderType" = "Opaque"
			"Queue" = "Geometry"
			"VRCFallback" = "Hidden"
		}
		
        Pass
        {
            CGPROGRAM
            #pragma target 5.0
            #pragma vertex vert
            #pragma fragment frag
			#pragma multi_compile_instancing
            #include "UnityCG.cginc"

            struct appdata
            {
                float4 position_os : POSITION;
				UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct v2f
            {
                float4 position_cs : SV_POSITION;
                float3 position_ws : TEXCOORD0;
                float3 eye_vector_ws : TEXCOORD1;
				UNITY_VERTEX_OUTPUT_STEREO
            };

            v2f vert (appdata v)
            {
                v2f o;
				UNITY_SETUP_INSTANCE_ID(v);
				UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                o.position_cs = UnityObjectToClipPos(v.position_os);
                o.position_ws = mul(unity_ObjectToWorld, v.position_os).xyz;
                o.eye_vector_ws = mul(unity_ObjectToWorld, v.position_os).xyz - _WorldSpaceCameraPos;
                return o;
            }

            float3 glsl_mod(float3 x, float y) {
                return x - y * floor(x / y); 
            }

            float kaliset_fractal(float3 position) {
                const int iterations = 17; // Seen in almost all variations
                const float sparsity = 0.5;
                
                float previous_len = 0;
                float accumulator = 0;
                for (int i = 0; i < iterations; i++) {
                    position = abs(position) / dot(position, position) - sparsity;
                    float len = length(position);
                    accumulator += abs(len - previous_len);
                    previous_len = len;
                }
                return accumulator;
            }

            fixed4 frag (v2f i) : SV_Target
            {
				UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                // Constants
                const int volumetric_steps = 8;
                const float stepsize = 0.2;

                const float tile = 0.850;

                const float brightness = 0.0018;
                const fixed distfading = 0.6800;
                const fixed saturation = 0.850;

                // Camera
                float3 camera_forward_ws = unity_CameraToWorld._m02_m12_m22;
                float3 eye_dir_ws = i.eye_vector_ws / dot(i.eye_vector_ws, camera_forward_ws);
                float3 origin = _WorldSpaceCameraPos;
                
                // Code
                float depth = 0.1; // Goes from 0 to 2 in the original shader
                fixed fade = 1.;
                fixed3 color = 0;
                for (int r = 0; r < volumetric_steps; r++) {
                    float3 position = origin + (depth * 0.5) * eye_dir_ws;

                    position = abs(tile - glsl_mod(position, tile * 2.)); // tiling fold

                    float a = kaliset_fractal(position);
                    
                    a *= a * a; // add contrast
                    color += (fixed3(depth, depth * depth, depth * depth * depth) * a * brightness + 1.) * fade; // coloring based on distance
                    fade *= distfading; // distance fading
                    depth += stepsize;
                }
                color = lerp(length(color), color, saturation); //color adjust
                return fixed4(color * 0.01, 1);
            }
            ENDCG
        }
    }
}