#if UNITY_EDITOR
using System.Linq;
using System.Collections.Generic;
using UnityEngine;
using UnityEditor;
using System.IO;
using System.Globalization;
using System;

// Embed simple skinning and bone rotation animations into a shader, driven by time.
// Requires a skinned mesh prefab to extract armature data, and an animation on transforms to extract angle curves from.
// 
// Skinning is GPU side, and cannot precompute the transform chains.
// Thus we apply 1D rotations in sequence. 4 needed to handle the robotic replicator insect.
// Works only with robotic stuff : no partial weight (1 or 0), and simple rotations are visually ok.
// Only some axis of transforms are animated (to have 1d rotations), and they are explictely selected.
// IMPORTANT : align transforms so that they are aligned to selected axis, and have no constant rotations to care about.
// Stores rotation location data in constants, a sequence of rotation id in a table by bone_id, and bone_id in uv1.x for each vertex.
//
// Animation stuff : sample curves for the selected axis only. Curve points are sampled on a fixed interval.
// During animation, use simple lerp between successive sample points. If not smooth just add more points.
// Encoding the splines themselves would use less memory but require finding keyframes at less predictable timestamps ; not worth it.

[assembly: nadena.dev.ndmf.ExportsPlugin(typeof(Lereldarion.ReplicatorConfigurePetPlugin))]

namespace Lereldarion {
    // Hook to GUI
    [CustomEditor(typeof(ReplicatorConfigurePet), true)]
    public class ReplicatorConfigurePet_Editor : Editor {
        public override void OnInspectorGUI() {
            var component = (ReplicatorConfigurePet) target;
            DrawDefaultInspector();
            if (GUILayout.Button("Configure")) { component.ConfigurePet(); }
        }
    }

    // Hook to ndmf for auto launch
    public class ReplicatorConfigurePetPlugin : nadena.dev.ndmf.Plugin<ReplicatorConfigurePetPlugin> {
        public override string DisplayName => "Configure Replicator Pet : set Mesh UVs and Shader baked data";

        protected override void Configure() {
            InPhase(nadena.dev.ndmf.BuildPhase.Generating).Run("Configure Replicator Pet", ctx => {
                var component = ctx.AvatarRootObject.GetComponentInChildren<ReplicatorConfigurePet>(true);
                if (component != null) {
                    component.ConfigurePet();
                }
            });
        }
    }

    public class ReplicatorConfigurePet : MonoBehaviour, VRC.SDKBase.IEditorOnly
    {
        // Component fields
        public SkinnedMeshRenderer skinned_renderer;
        public AnimationClip walking_clip;
        [Range(1f, 60f)]
        public float samples_per_second;
        public AnimationClip cower_clip;

        ///////////////////////////////////////////
        
        private enum Axis { X, Y, Z }
        static private readonly Dictionary<string, Axis> rotation_axis_property_names = new Dictionary<string, Axis>{
            {"localEulerAnglesRaw.x", Axis.X},
            {"localEulerAnglesRaw.y", Axis.Y},
            {"localEulerAnglesRaw.z", Axis.Z}
        };

        // Axis sequence : apply from leaf bones to root, from left to right of lists.
        // Axis are from transform localEulerAngles. No direction selected. Unspecified bones are ignored.
        static private readonly Dictionary<string, Axis[]> rotation_axis_sequence_for_bones = new Dictionary<string, Axis[]> {
            // 4 DOF for backleg
            {"BackLeg0", new[]{Axis.X, Axis.Y}},
            {"BackLeg1", new[]{Axis.X}},
            {"BackLeg2", new[]{Axis.X}},
            // 4 DOF for front leg
            {"FrontLeg0", new[]{Axis.Z}},
            {"FrontLeg1", new[]{Axis.Z}},
            {"FrontLeg2", new[]{Axis.Z}},
            {"FrontLeg3", new[]{Axis.Z}},
        };

        public void ConfigurePet() {
            BoneScanResult armature = scan_bones(this.skinned_renderer);
            float[] distances_core_01 = compute_distance_core_01(this.skinned_renderer);
            copy_bone_id_and_core_distances_to_uv1(this.skinned_renderer, armature.bone_id_for_name, distances_core_01);
            var walking = generate_walking_animation_sample_table(this.walking_clip, this.samples_per_second, armature);
            var cower_rotations = extract_cower_rotations(this.cower_clip, armature);

            string shader_data_path = $"{Application.dataPath}/Avatar/pet/pet_data.orlsource"; // hlsl fragment with extra tags
            using (StreamWriter writer = File.CreateText(shader_data_path)) {
                string to_string_f(float v) => v.ToString("G", CultureInfo.InvariantCulture);
                string to_string_v3(Vector3 v) => $"float3({to_string_f(v.x)}, {to_string_f(v.y)}, {to_string_f(v.z)})";

                writer.WriteLine("%LibraryFunctions() {");
                writer.WriteLine("// Shader data for pet replicator animation : emulated skinning transforms and animation tracks");
                writer.WriteLine();
                writer.WriteLine("// Rotation tables");
                writer.WriteLine("struct RotationConfigOs { float3 axis; float3 center; };");
                writer.WriteLine($"static const RotationConfigOs rotation_config_os[{armature.rotation_table.Count}] = {{");
                foreach(RotationConfigOs rot in armature.rotation_table) {
                    writer.WriteLine($"    {{ {to_string_v3(rot.axis)}, {to_string_v3(rot.center)} }},");
                }
                writer.WriteLine("};");
                writer.WriteLine();
                writer.WriteLine("// Bone id to rotation id sequence");
                writer.WriteLine($"static const int4 bone_id_rotation_sequence[{armature.bone_id_to_rotation_sequence.Count}] = {{");
                foreach(List<int> sequence in armature.bone_id_to_rotation_sequence) {
                    Debug.Assert(sequence.Count == 4);
                    writer.WriteLine($"    int4({string.Join(", ", sequence)}),");
                }
                writer.WriteLine("};");
                writer.WriteLine();
                writer.WriteLine("// Animation curves");
                writer.WriteLine($"static const int walking_animation_sample_count = {walking.sample_count};");
                writer.WriteLine($"static const float walking_animation_sample_interval = {to_string_f(this.walking_clip.length / walking.sample_count)};");
                writer.WriteLine($"static const float walking_animation_samples[{walking.sample_count + 1}][{armature.rotation_table.Count}] = {{");
                for (int s = 0; s <= walking.sample_count; s += 1) {
                    // write 1 more sample line, equal to first, to prevent another modulo in shader
                    int sample_id = s % walking.sample_count;
                    string samples = string.Join(", ", Enumerable.Range(0, armature.rotation_table.Count).Select(r => to_string_f(walking.samples[r][sample_id])));
                    writer.WriteLine($"    {{ {samples} }},");
                }
                writer.WriteLine("};");
                writer.WriteLine();
                writer.WriteLine($"static const float cower_rotation_offsets[{armature.rotation_table.Count}] = {{");
                writer.WriteLine("    {0}", string.Join(", ", cower_rotations.Select(to_string_f)));
                writer.WriteLine("};");
                writer.WriteLine("}");
            }
            Debug.Log($"Written : {shader_data_path}");
        }

        private class RotationConfigOs {
            // Coordinate in mesh object space
            public Vector3 axis;
            public Vector3 center;
        }
        private class BoneScanResult {
            public List<RotationConfigOs> rotation_table;
            
            public Dictionary<string, int> bone_id_for_name; // bone name -> bone id
            public List<List<int>> bone_id_to_rotation_sequence; // bone_id -> List<rotation_id> to apply from leaf to root

            public Dictionary<(string, Axis), (int, float)> bone_axis_to_rotation_id_and_rest_value;

            public BoneScanResult() {
                rotation_table = new List<RotationConfigOs>{
                    // add dummy rotation that is never used or animated. used to pad rotation sequences to 4 with inert rotations
                    new RotationConfigOs{ axis = Vector3.up, center = Vector3.zero }
                };

                bone_id_for_name = new Dictionary<string, int>();
                bone_id_to_rotation_sequence = new List<List<int>>();

                bone_axis_to_rotation_id_and_rest_value = new Dictionary<(string, Axis), (int, float)>();
            }
        }
        static private BoneScanResult scan_bones(SkinnedMeshRenderer renderer) {
            BoneScanResult result = new BoneScanResult();
            void scan(Transform bone) {
                // Identify bone by name. Ignore side prefix ; table applies to both sides.
                string base_name = string.Copy(bone.name);
                if (base_name.StartsWith("Left")) { base_name = base_name.Remove(0, 4); }
                else if (base_name.StartsWith("Right")) { base_name = base_name.Remove(0, 5); }
                
                // Build non-noop rotation sequence. Padding is applied later.
                List<int> rotation_sequence = new List<int>();
                // Add new rotations first
                if (rotation_axis_sequence_for_bones.ContainsKey(base_name)) {
                    Vector3 center_os = renderer.transform.InverseTransformPoint(bone.position);
                    foreach (Axis axis in rotation_axis_sequence_for_bones[base_name]) {
                        Vector3 axis_ws = Vector3.zero;
                        float rest_angle = 0; // shader rotations are from 0 ; unity transform start rotated ; substract rest angle later.
                        switch (axis) {
                            case Axis.X: axis_ws = bone.right; rest_angle = bone.localEulerAngles.x; break;
                            case Axis.Y: axis_ws = bone.up; rest_angle = bone.localEulerAngles.y; break;
                            case Axis.Z: axis_ws = bone.forward; rest_angle = bone.localEulerAngles.z; break;
                        }
                        int rotation_id = result.rotation_table.Count;
                        result.rotation_table.Add(new RotationConfigOs{
                            axis = renderer.transform.InverseTransformDirection(axis_ws),
                            center = center_os
                        });
                        result.bone_axis_to_rotation_id_and_rest_value.Add((bone.name, axis), (rotation_id, rest_angle));
                        rotation_sequence.Add(rotation_id);
                    }
                }
                // Continue with parent rotations if applicable
                if (bone != renderer.rootBone) {
                    int parent_bone_id = result.bone_id_for_name[bone.parent.name];
                    foreach(int id in result.bone_id_to_rotation_sequence[parent_bone_id]) {
                        rotation_sequence.Add(id);
                    }
                }

                // Register new bone
                int bone_id = result.bone_id_to_rotation_sequence.Count;
                result.bone_id_for_name.Add(bone.name, bone_id);
                result.bone_id_to_rotation_sequence.Add(rotation_sequence);

                foreach (Transform child in bone) {
                    scan(child);
                }
            }
            scan(renderer.rootBone);

            // Pad rotation sequences
            int max_rotation_sequence_len = result.bone_id_to_rotation_sequence.Max(sequence => sequence.Count);
            Debug.Log($"Max rotation sequence: {max_rotation_sequence_len}");
            foreach(var sequence in result.bone_id_to_rotation_sequence) {
                while(sequence.Count < max_rotation_sequence_len) {
                    sequence.Insert(0, 0);
                }
            }

            return result;
        }

        static private void copy_bone_id_and_core_distances_to_uv1(SkinnedMeshRenderer renderer, Dictionary<string, int> bone_id_for_name, float[] core_distances_01) {
            // https://docs.unity3d.com/ScriptReference/Mesh.GetAllBoneWeights.html
            Mesh mesh = renderer.sharedMesh;
            Transform[] bones = renderer.bones;
            var bone_per_vertex = mesh.GetBonesPerVertex();
            var bone_weights = mesh.GetAllBoneWeights();

            var uv1 = new Vector2[mesh.vertexCount];

            var bone_weight_iterator = 0;
            for (int vertex_id = 0; vertex_id < mesh.vertexCount; vertex_id += 1) {
                // For each vertex, set uv1 to match the bone id of the vertex. rotation sequence is retrieved from an indirection table.
                Transform bone = bones[bone_weights[bone_weight_iterator].boneIndex];
                int bone_id = bone_id_for_name[bone.name];
                uv1[vertex_id].x = (float) bone_id;
                uv1[vertex_id].y = core_distances_01[vertex_id];
                bone_weight_iterator += bone_per_vertex[vertex_id];
            }

            mesh.SetUVs(1, uv1);
        }

        // Extract walking animation as a sampled set of curves. Use mirroring to avoid editing both sides.
        private class WalkingAnimationData {
            public int sample_count;
            public float[][] samples; // [rotation][t]
            
            public WalkingAnimationData(int n_rotation, int n_samples) {
                sample_count = n_samples;
                samples = new float[n_rotation][];
                for (int r = 0; r < n_rotation; r += 1) {
                    samples[r] = Enumerable.Repeat(0f, n_samples).ToArray();
                }
            } 
        }
        static private WalkingAnimationData generate_walking_animation_sample_table(AnimationClip clip, float samples_per_second, BoneScanResult armature) {
            int nb_sample = Mathf.RoundToInt(clip.length * samples_per_second);
            if (nb_sample % 2 == 1) { nb_sample += 1; } // make it even to allow copy of samples shifted by half period to be exact

            var result = new WalkingAnimationData (armature.rotation_table.Count, nb_sample);
            float sample_interval = clip.length / (float) nb_sample;

            int curve_converted = 0;
            foreach(var binding in AnimationUtility.GetCurveBindings(clip)) {
                // Identify rotation id for curve
                if (!rotation_axis_property_names.ContainsKey(binding.propertyName)) {
                    Debug.LogWarning($"Unsupported property name {binding.propertyName} ; ensure animation rotations are in euler interpolation");
                    continue ;
                }
                Axis axis = rotation_axis_property_names[binding.propertyName];
                string bone_name = binding.path.Split('/').Last();
                if (!armature.bone_axis_to_rotation_id_and_rest_value.ContainsKey((bone_name, axis))) { continue; }
                var (rotation_id, rest_angle) = armature.bone_axis_to_rotation_id_and_rest_value[(bone_name, axis)];
                var curve = AnimationUtility.GetEditorCurve(clip, binding);
                // Sampling. Assume looping curve, so do not sample last point (== first).
                for (int s = 0; s < nb_sample; s += 1) {
                    float sample_degree = curve.Evaluate(sample_interval * s) - rest_angle;
                    float sample_radians = sample_degree * ((float) Math.PI / 180f);
                    result.samples[rotation_id][s] = sample_radians;
                }
                curve_converted += 1;

                // Mirror curve on right side. Avoids the need to copy-paste shifted curves everywhere, but requires careful transform positionning.
                if (bone_name.StartsWith("Left")) {
                    string mirror_bone = "Right" + bone_name.Remove(0, 4);

                    // Exact mirroring factors. Ugly but faster than manual animation copy and shift...
                    float mirroring = -1;
                    if (bone_name.Contains("LeftBackLeg") && axis != Axis.Y) {
                        mirroring = 1;
                    }

                    var (mirror_rotation_id, _) = armature.bone_axis_to_rotation_id_and_rest_value[(mirror_bone, axis)];
                    for (int s = 0; s < nb_sample; s += 1) {
                        result.samples[mirror_rotation_id][(s + nb_sample/2) % nb_sample] = mirroring * result.samples[rotation_id][s];
                    }
                    curve_converted += 1;
                }
            }
            Debug.Log($"Walking animation curve sampled : {curve_converted}/{armature.rotation_table.Count} ; nb_samples = {nb_sample}");
            return result;
        }

        // Cower position offset, defined as a single frame animation.
        // Beware of euler angles ! Animation sets RightBackLeg0.y to 179.9 to avoid a full rotation due to mod 2pi
        static private float[] extract_cower_rotations(AnimationClip clip, BoneScanResult armature) {
            float[] rotations = Enumerable.Repeat(0f, armature.rotation_table.Count).ToArray();

            int curve_converted = 0;
            foreach(var binding in AnimationUtility.GetCurveBindings(clip)) {
                // Identify rotation id for curve
                if (!rotation_axis_property_names.ContainsKey(binding.propertyName)) {
                    Debug.LogWarning($"Unsupported property name {binding.propertyName} ; ensure animation rotations are in euler interpolation");
                    continue ;
                }
                Axis axis = rotation_axis_property_names[binding.propertyName];
                string bone_name = binding.path.Split('/').Last();
                if (!armature.bone_axis_to_rotation_id_and_rest_value.ContainsKey((bone_name, axis))) { continue; }
                var (rotation_id, rest_angle) = armature.bone_axis_to_rotation_id_and_rest_value[(bone_name, axis)];
                var curve = AnimationUtility.GetEditorCurve(clip, binding);
                // Sampling
                float sample_degree = curve.Evaluate(0f) - rest_angle;
                float sample_radians = sample_degree * ((float) Math.PI / 180f);
                rotations[rotation_id] = sample_radians;
                curve_converted += 1;
            }
            Debug.Log($"Cower rotations extracted : {curve_converted}/{armature.rotation_table.Count}");
            return rotations;
        }

        // Create a 01 coordinate from center to ends for audiolink effects (similar to avatar)
        static private Vector3[] compute_vertice_triangle_barycenters(Mesh mesh) {
            // For animations, it is better to use triangle center coordinates instead of a random vertex.
            // Especially for arm cut which is precise.
            // This function returns an array (indexes by vertex id) for the barycenter of triangle the vertex is part of.
            // This is ambiguous for triangles sharing vertices, but this is not the case for replicator blocks. FIXME when UV are used for detail material animations.
            Vector3[] vertices = mesh.vertices;
            int[] triangles = mesh.triangles;
            var vertice_triangle_barycenters = new Vector3[mesh.vertexCount];
            for (int i = 0; i < triangles.Length; i += 3) {
                int a = triangles[i];
                int b = triangles[i + 1];
                int c = triangles[i + 2];
                Vector3 barycenter = (1f/3f) * (vertices[a] + vertices[b] + vertices[c]);
                vertice_triangle_barycenters[a] = barycenter;
                vertice_triangle_barycenters[b] = barycenter;
                vertice_triangle_barycenters[c] = barycenter;
            }
            return vertice_triangle_barycenters;
        }
        static private float[] compute_distance_core_01(SkinnedMeshRenderer renderer) {
            Vector3[] triangle_barycenter_os = compute_vertice_triangle_barycenters(renderer.sharedMesh);
            Vector3 center_os = renderer.transform.InverseTransformPoint(renderer.rootBone.position);
            float max_distance = triangle_barycenter_os.Max(pos => Vector3.Distance(pos, center_os));
            return triangle_barycenter_os.Select(pos => Vector3.Distance(pos, center_os) / max_distance).ToArray();
        }

    }
}
#endif