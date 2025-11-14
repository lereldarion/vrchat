Shader "Lereldarion/LavaSim/BlackBodyDebug" {
    Properties {
        _LavaSim_Temperature("Temperature Celsius", Range(0, 1600)) = 1473
        [NoScaleOffset] _LavaSim_Black_Body("Black body texture", 2D) = "" {}
        _LavaSim_Black_Body_Scale("Black body emission scaling", Range(0, 1)) = 1
    }
    SubShader {
        Tags {
            "RenderType" = "Opaque"
            "Queue" = "Geometry"
            "IgnoreProjector" = "True"
        }

        Pass {
            Cull Back
            ZTest LEqual
            ZWrite On
            Blend Off

            CGPROGRAM
            #pragma target 5.0
            #pragma multi_compile_instancing

            #pragma vertex vertex_stage
            #pragma fragment fragment_stage

            #include "UnityCG.cginc"

            struct VertexData {
                float4 position : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct FragmentInput {
                float4 position_cs : SV_POSITION;
                fixed3 color : BLACK_BODY;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            uniform float _LavaSim_Temperature;
            
            uniform Texture2D<float4> _LavaSim_Black_Body;
            uniform SamplerState sampler_LavaSim_Black_Body;
            uniform float _LavaSim_Black_Body_Scale;


            void vertex_stage(VertexData input, out FragmentInput output) {
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                // Black body radiation.
                const float temperature_range = 1024;
                const float max_temperature = 1600;
                const float min_temperature = max_temperature - temperature_range;
                const float temperature_x = ((_LavaSim_Temperature /*+ 273.15*/) - min_temperature) / temperature_range;
                output.color = _LavaSim_Black_Body.SampleLevel(sampler_LavaSim_Black_Body, float2(temperature_x, 0), 0 /*mip*/).rgb * _LavaSim_Black_Body_Scale;

                output.position_cs = UnityObjectToClipPos(input.position);
            }

            fixed4 fragment_stage(FragmentInput input) : SV_Target {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                return fixed4(input.color, 1);
            }
            ENDCG            
        }
    }
}