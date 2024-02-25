Shader "Lereldarion/PortalWindow" {
    Properties {
        _WorldTex ("World Texture", 2D) = "black" {}
        _TimerEnd("Timer end", float) = 0
        //_TimerTest("Timer override test", Range(0, 1)) = 0
    }
    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        LOD 100

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            // make fog work
            #pragma multi_compile_fog
            #pragma multi_compile_instancing

            #include "UnityCG.cginc"

            struct appdata {
                float4 vertex : POSITION;
                float3 normal : NORMAL;
                float4 tangent : TANGENT;
                float2 uv : TEXCOORD0;
            };

            struct v2f {
                float4 vertex : SV_POSITION;
                float3 uvx_os : UVX;
                float3 uvy_os : UVY;
                float3 camera_to_geometry_os : VIEW_VECTOR;
                float uv_blend_factor : UV_BLEND_FACTOR;
                float2 uv : TEXCOORD0;
                UNITY_FOG_COORDS(1)
            };

            uniform sampler2D _WorldTex;
            uniform float4 _WorldTex_ST;

            static const float _TimerRange = 30; // secs
            uniform float _TimerEnd;
            //uniform float _TimerTest;

            float3 camera_ws() {
                #if UNITY_SINGLE_PASS_STEREO
                return 0.5 * (unity_StereoWorldSpaceCameraPos[0] + unity_StereoWorldSpaceCameraPos[1]); // Avoid eye inconsistency, take center;
                #else
                return _WorldSpaceCameraPos;
                #endif
            }

            v2f vert (appdata i) {
                v2f o;
                o.vertex = UnityObjectToClipPos(i.vertex);
                o.uv = i.uv;
                UNITY_TRANSFER_FOG(o, o.vertex);

                o.uvx_os = i.tangent;
                o.uvy_os = normalize(cross(i.tangent, i.normal) * i.tangent.w * -1);
                o.camera_to_geometry_os = -ObjSpaceViewDir(i.vertex);

                float3 object_base_ws = unity_ObjectToWorld._m03_m13_m23;
                o.uv_blend_factor = smoothstep(3, 15, distance(object_base_ws, camera_ws()));
                return o;
            }

            fixed4 frag (v2f i) : SV_Target {
                float3 view_ray = normalize(i.camera_to_geometry_os);
                float2 projection_uv = 0.5 + 0.5 * float2(
                    dot(view_ray, i.uvx_os),
                    dot(view_ray, i.uvy_os)
                );
                fixed4 final_color = tex2D(_WorldTex, lerp(projection_uv, i.uv, i.uv_blend_factor));

                float time_remaining_01 = saturate((_TimerEnd - _Time.y) / _TimerRange);
                //if(_TimerTest > 0) { time_remaining_01 = _TimerTest; }

                // Slowly turn to grayscale from 1 -> mode_change_time
                // Oval cutoff black from mode_change_time -> 0
                const float mode_change_time = 0.2;
                const float color_fraction = saturate((time_remaining_01 - mode_change_time) / (1 - mode_change_time));
                const float visible_fraction = saturate(time_remaining_01 / mode_change_time);

                // Grayscalification
                fixed3 grayscale_color = 0.9 * fixed3(1, 1, 1) * (final_color.r + final_color.g + final_color.b) / 3;
                final_color.rgb = lerp(grayscale_color, final_color.rgb, color_fraction);

                // Oval cutoff
                const float cutoff_transition = 0.1;
                float2 centered_uv = i.uv - 0.5;
                float pixel_oval_radius_sq = dot(centered_uv, centered_uv);
                float cutoff_radius_one_dimension = visible_fraction * (0.5 + cutoff_transition);
                float cutoff_radius_sq = 2 * cutoff_radius_one_dimension * cutoff_radius_one_dimension; // (0.5 * frac)^2 * 2
                final_color.rgb *= smoothstep(0, cutoff_transition, cutoff_radius_sq - pixel_oval_radius_sq);

                UNITY_APPLY_FOG(i.fogCoord, final_color);
                return final_color;
            }
            ENDCG
        }
    }
}
