#if UNITY_EDITOR
using System.Linq;
using System.Text.RegularExpressions;
using UnityEngine;
using UnityEditor;
using VRC.SDK3.Dynamics.Contact.Components;

namespace Lereldarion {
    public class ReplicatorSetDislocationUVs : MonoBehaviour
    {
        public SkinnedMeshRenderer main_mesh;

        [Header("Spatial coordinates")]
        public Transform bottom_l1_distance_origin;
        public Transform core_distance_01_origin;

        [Header("Dynamic elements")]
        public Transform override_position;

        public Transform[] dynamic_element_roots;

        [Header("Arm dislocation")]
        public Transform left_arm_root;
        public VRCContactReceiver left_arm_proximity;
        public Transform shield;
        public Transform right_arm_root;
        public VRCContactReceiver right_arm_proximity;
    }

    [CustomEditor(typeof(ReplicatorSetDislocationUVs), true)]
    public class ReplicatorSetDislocationUVs_Editor : Editor {

        private enum Role {
            None,
            DynamicElement, // relocatable elements
            LeftArm,
            RightArm,
        }
        private void SetUVs() {
            var editor = (ReplicatorSetDislocationUVs) target;

            // Using the raw mesh + transforms
            Mesh mesh = editor.main_mesh.sharedMesh;
            Role[] roles = identify_vertice_roles(editor);
            Vector3[] vertice_triangle_barycenters = compute_vertice_triangle_barycenters(mesh);
            
            // Uv maps
            Vector2[] uv1 = Enumerable.Repeat(Vector2.zero, mesh.vertexCount).ToArray(); // (global_dislocation_spatial_delay, distance_to_core_01)
            Vector2[] uv2 = Enumerable.Repeat(Vector2.zero, mesh.vertexCount).ToArray(); // (limb_id, limb_metric) ; limb_id usually given by enum value of role for simplicity

            // Compute spatial coordinates :
            // - An offset for animation time so that dislocation/reassembly is gradual, from bottom to extremities.
            //   Offset is defined as a positive delay, with 0 as minimum at maximum distance from bottom.
            //   Using L1 distance from bottom.
            // - Normalized distance from cristal "core", in [0,1]
            Vector3 bottom_l1_distance_origin = editor.main_mesh.transform.InverseTransformPoint(editor.bottom_l1_distance_origin.position);
            Vector3 core_distance_01_origin = editor.main_mesh.transform.InverseTransformPoint(editor.core_distance_01_origin.position);
            Vector3 extremity_position_override_os = editor.main_mesh.transform.InverseTransformPoint(editor.override_position.position);

            float[] bottom_l1_distances = new float[mesh.vertexCount];
            float[] core_l2_distances = new float[mesh.vertexCount];
            for (int i = 0; i < mesh.vertexCount; i += 1) {
                var position_os = vertice_triangle_barycenters[i];
                if (roles[i] == Role.DynamicElement) {
                    position_os = extremity_position_override_os;
                }

                bottom_l1_distances[i] = l1_norm(position_os - bottom_l1_distance_origin);
                core_l2_distances[i] = Vector3.Distance(position_os, core_distance_01_origin);
            }

            float bottom_l1_distance_max = bottom_l1_distances.Max();
            float core_l2_distance_max = core_l2_distances.Max() * 1.01f; // [0,1[ to include toes
            for (int i = 0; i < mesh.vertexCount; i += 1) {
                uv1[i].x = bottom_l1_distance_max - bottom_l1_distances[i];
                uv1[i].y = core_l2_distances[i] / core_l2_distance_max;
            }

            // Arms : compute a limb_linear_distance scaled & centered to the proximity contact, with -1 towards spine and +1 towards fingers.
            // Easy only because model is in strict T-pose, we can project on an axis
            var left_arm_config = new ArmConfiguration(editor.left_arm_proximity, editor.main_mesh.transform);
            var right_arm_config = new ArmConfiguration(editor.right_arm_proximity, editor.main_mesh.transform);
            for (int i = 0; i < mesh.vertexCount; i += 1) {
                if (roles[i] == Role.LeftArm) {
                    uv2[i].x = (float) Role.LeftArm;
                    uv2[i].y = left_arm_config.AxisProjectionScaled(vertice_triangle_barycenters[i]);
                }
                if (roles[i] == Role.RightArm) {
                    uv2[i].x = (float) Role.RightArm;
                    uv2[i].y = right_arm_config.AxisProjectionScaled(vertice_triangle_barycenters[i]);
                }
            }
            Debug.Log($"LeftArm min={uv2.Where(uv => uv.x == (float) Role.LeftArm).Select(uv => uv.y).Min()} max={uv2.Where(uv => uv.x == (float) Role.LeftArm).Select(uv => uv.y).Max()}");

            mesh.SetUVs(1, uv1);
            mesh.SetUVs(2, uv2);
        }

        static private float l1_norm(Vector3 v) {
            return Mathf.Abs(v.x) + Mathf.Abs(v.y) + Mathf.Abs(v.z);
        }

        static private Role[] identify_vertice_roles(ReplicatorSetDislocationUVs editor) {
            // https://docs.unity3d.com/ScriptReference/Mesh.GetAllBoneWeights.html
            Mesh mesh = editor.main_mesh.sharedMesh;
            Transform[] bones = editor.main_mesh.bones;
            var bone_per_vertex = mesh.GetBonesPerVertex();
            var bone_weights = mesh.GetAllBoneWeights();
            
            var roles = new Role[mesh.vertexCount];
            var bone_weight_iterator = 0;
            for (int vertex_id = 0; vertex_id < mesh.vertexCount; vertex_id += 1) {
                // For each vertex, assign a role from bone names.
                // Use the first one with a role ; unity gives bones by decreasing weights so this should be ok even for non robotic stuff.
                var role = Role.None;
                var iterator_end = bone_weight_iterator + bone_per_vertex[vertex_id];
                for (; bone_weight_iterator < iterator_end; bone_weight_iterator += 1) {
                    if (role != Role.None) { continue; } // Already assigned
                    Transform bone = bones[bone_weights[bone_weight_iterator].boneIndex];
                    if (editor.dynamic_element_roots.Any(root => bone.IsChildOf(root))) {
                        role = Role.DynamicElement;
                    } else if (bone.IsChildOf(editor.shield)) {
                        role = Role.LeftArm; // Always attached to left arm, no need to isolate it for dislocation
                    } else if (bone.IsChildOf(editor.left_arm_root)) {
                        role = Role.LeftArm;
                    } else if (bone.IsChildOf(editor.right_arm_root)) {
                        role = Role.RightArm;
                    }
                }
                roles[vertex_id] = role;
            }
            Debug.Log($"Role vertex counts: dynamic = {roles.Where(r => r == Role.DynamicElement).Count()}, left arm = {roles.Where(r => r == Role.LeftArm).Count()}");
            return roles;
        }

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

        private struct ArmConfiguration {
            private Vector3 origin_os;
            private Vector3 axis_os;
            private float scale_factor;

            public ArmConfiguration(VRCContactReceiver proximity, Transform mesh_transform) {
                Debug.Assert(proximity.shapeType == VRCContactReceiver.ShapeType.Sphere);
                Debug.Assert(proximity.receiverType == VRCContactReceiver.ReceiverType.Proximity);

                var contact_ws = proximity.transform.position + proximity.transform.TransformVector(proximity.position);
                origin_os = mesh_transform.InverseTransformPoint(contact_ws);

                var axis_radius_local = Vector3.up * proximity.radius; // up is the green one, pointing towards +1.
                var axis_radius_os = mesh_transform.InverseTransformVector(proximity.transform.TransformVector(axis_radius_local));
                axis_os = axis_radius_os.normalized;
                scale_factor = axis_radius_os.magnitude;
            }

            public float AxisProjectionScaled(Vector3 position_os) {
                float r = Vector3.Dot(axis_os, position_os - origin_os) / scale_factor;
                Debug.Assert(-1f <= r && r <= 1f);
                return r;
            }
        };

        public override void OnInspectorGUI() {
            DrawDefaultInspector();
            if (GUILayout.Button("Set UV")) { SetUVs(); }
        }
    }
}
#endif