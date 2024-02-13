#if UNITY_EDITOR
using System.Linq;
using UnityEngine;
using UnityEditor;
using VRC.SDK3.Dynamics.Contact.Components;
using UnityEngine.Rendering;
using UnityEditor.VersionControl;
using System.Collections.Generic;

[assembly: nadena.dev.ndmf.ExportsPlugin(typeof(Lereldarion.ReplicatorConfigureAvatarPlugin))]

namespace Lereldarion {
    // Hook to GUI
    [CustomEditor(typeof(ReplicatorConfigureAvatar), true)]
    public class ReplicatorConfigureAvatar_Editor : Editor {
        public override void OnInspectorGUI() {
            var component = (ReplicatorConfigureAvatar) target;
            DrawDefaultInspector();
            if (GUILayout.Button("Configure")) { component.ConfigureAvatar(); }
        }
    }

    // Hook to ndmf for auto launch
    public class ReplicatorConfigureAvatarPlugin : nadena.dev.ndmf.Plugin<ReplicatorConfigureAvatarPlugin> {
        public override string DisplayName => "Configure Replicator Avatar : set Mesh UVs metadata for dislocation";

        protected override void Configure() {
            InPhase(nadena.dev.ndmf.BuildPhase.Generating).Run("Configure Replicator Avatar Mesh", ctx => {
                var component = ctx.AvatarRootObject.GetComponentInChildren<ReplicatorConfigureAvatar>(true);
                if (component != null) {
                    component.ConfigureAvatar();
                }
            });
        }
    }

    public class ReplicatorConfigureAvatar : MonoBehaviour, VRC.SDKBase.IEditorOnly {
        // Component Fields
        public SkinnedMeshRenderer skinned_renderer;
        public Material block_material;

        [Header("Spatial coordinates")]
        public Transform bottom_l1_distance_origin;
        public Transform core_distance_01_origin;

        [Header("Dynamic elements")]
        public Transform override_position;

        public Transform[] relocatable_element_roots;

        [Header("Arm dislocation")]
        public Transform left_arm_root;
        public VRCContactReceiver left_arm_proximity;
        public Transform right_arm_root;
        public VRCContactReceiver right_arm_proximity;
        public Transform left_leg_root;
        public VRCContactReceiver left_leg_proximity;

        /////////////////////////////////////////////////////////////
        
        private enum Role {
            // These constants are in sync with the shader !
            LeftArm = 1,
            RightArm = 2,
            LeftLeg = 3,
            // Not these ones
            RelocatableElement, // elements that move significantly ; ignore their positions
            Unassigned, // No specific role
            NotBlock, // other submeshes, for stats only
        }

        public void ConfigureAvatar() {
            // We will create UV maps for the block submesh of the avatar mesh.
            // UV maps for other submeshes are ignored and kept as is.
            // For simplicity we create array of data indexed by global vertex_id, but usually undefined or unused outside of block submesh 
            Mesh mesh = this.skinned_renderer.sharedMesh;
            int block_submesh_index = submesh_index_for_material(this.skinned_renderer, this.block_material);
            SubMeshDescriptor submesh = mesh.GetSubMesh(block_submesh_index);

            Vector3[] vertex_positions = vertex_positions_for_animation(mesh, block_submesh_index);
            Role[] roles = identify_vertice_roles(mesh, role_for_bones(this, this.skinned_renderer.bones), submesh);

            // Compute spatial coordinates :
            // - An offset for animation time so that dislocation/reassembly is gradual, from bottom to extremities.
            //   Offset is defined as a positive delay, with 0 as minimum at maximum distance from bottom.
            //   Using L1 distance from bottom.
            // - Normalized distance from cristal "core", in [0,1]
            Vector3 bottom_l1_distance_origin = this.skinned_renderer.transform.InverseTransformPoint(this.bottom_l1_distance_origin.position);
            Vector3 core_distance_01_origin = this.skinned_renderer.transform.InverseTransformPoint(this.core_distance_01_origin.position);
            Vector3 extremity_position_override_os = this.skinned_renderer.transform.InverseTransformPoint(this.override_position.position);

            float[] bottom_l1_distances = new float[submesh.vertexCount];
            float[] core_l2_distances = new float[submesh.vertexCount];
            for (int i = 0; i < submesh.vertexCount; i += 1) {
                var position_os = vertex_positions[i + submesh.firstVertex];
                if (roles[i + submesh.firstVertex] == Role.RelocatableElement) {
                    position_os = extremity_position_override_os;
                }

                bottom_l1_distances[i] = l1_norm(position_os - bottom_l1_distance_origin);
                core_l2_distances[i] = Vector3.Distance(position_os, core_distance_01_origin);
            }
            float bottom_l1_distance_max = bottom_l1_distances.Max();
            float core_l2_distance_max = core_l2_distances.Max() * 1.01f; // [0,1[ to include toes

            List<Vector2> uv1 = get_mesh_uv_or_default(mesh, 1);
            for (int i = 0; i < submesh.vertexCount; i += 1) {
                float global_dislocation_spatial_delay = bottom_l1_distance_max - bottom_l1_distances[i];
                float distance_to_core_01 = core_l2_distances[i] / core_l2_distance_max;
                uv1[i + submesh.firstVertex] = new Vector2(global_dislocation_spatial_delay, distance_to_core_01);
            }
            mesh.SetUVs(1, uv1);

            // Arms : compute a limb_linear_distance scaled & centered to the proximity contact, with -1 towards spine and +1 towards fingers.
            // Easy only because model is in strict T-pose, we can project on an axis
            var limb_referential = new Dictionary<Role, LimbAxisReferential>{
                { Role.LeftArm, new LimbAxisReferential(this.left_arm_proximity, this.skinned_renderer.transform)},
                { Role.RightArm, new LimbAxisReferential(this.right_arm_proximity, this.skinned_renderer.transform) },
                { Role.LeftLeg, new LimbAxisReferential(this.left_leg_proximity, this.skinned_renderer.transform) },
            };
            
            List<Vector2> uv2 = get_mesh_uv_or_default(mesh, 2);
            for (int i = 0; i < mesh.vertexCount; i += 1) {
                Role role = roles[i];
                LimbAxisReferential referential;
                if (limb_referential.TryGetValue(role, out referential)) {
                    uv2[i] = new Vector2((float) role, referential.axis_coordinate(vertex_positions[i])); // (limb_id, limb_metric)
                }
            }
            mesh.SetUVs(2, uv2);
            Debug.Log($"LeftArm min={uv2.Where(uv => uv.x == (float) Role.LeftArm).Select(uv => uv.y).Min()} max={uv2.Where(uv => uv.x == (float) Role.LeftArm).Select(uv => uv.y).Max()}");
        }

        ////////////////////////////////////////////////////////////////////////////////////////////
        ///
        static private int submesh_index_for_material(SkinnedMeshRenderer renderer, Material material) {
            Material[] slots = renderer.sharedMaterials;
            Debug.Assert(slots.Length == renderer.sharedMesh.subMeshCount);
            for (int i = 0; i < slots.Length; i += 1) {
                if (slots[i] == material) {
                    return i;
                }
            }
            throw new System.ArgumentException("Material not found in renderer");
        }

        static private List<Vector2> get_mesh_uv_or_default(Mesh mesh, int channel) {
            var uv = new List<Vector2>();
            mesh.GetUVs(channel, uv);
            if (uv.Count != mesh.vertexCount) {
                uv = Enumerable.Repeat(Vector2.zero, mesh.vertexCount).ToList();
            }
            return uv;
        }

        static private float l1_norm(Vector3 v) {
            return Mathf.Abs(v.x) + Mathf.Abs(v.y) + Mathf.Abs(v.z);
        }
        
        static private Role[] role_for_bones(ReplicatorConfigureAvatar definitions, Transform[] bones) {
            return bones.Select(bone => {
                if (definitions.relocatable_element_roots.Any(root => bone.IsChildOf(root))) {
                    return Role.RelocatableElement;
                } else if (bone.IsChildOf(definitions.left_arm_root)) {
                    return Role.LeftArm; // Shield included, not relocatable enough
                } else if (bone.IsChildOf(definitions.right_arm_root)) {
                    return Role.RightArm; // Tools included
                } else if (bone.IsChildOf(definitions.left_leg_root)) {
                    return Role.LeftLeg;
                }
                return Role.Unassigned;
            }).ToArray();
        }

        static private Role[] identify_vertice_roles(Mesh mesh, Role[] role_for_bone, SubMeshDescriptor submesh) {
            var roles = new Role[mesh.vertexCount];

            // https://docs.unity3d.com/ScriptReference/Mesh.GetAllBoneWeights.html iteration scheme
            var bone_per_vertex = mesh.GetBonesPerVertex();
            var bone_weights = mesh.GetAllBoneWeights();
            var bone_weight_iterator = 0;
            for (int vertex_id = 0; vertex_id < mesh.vertexCount; vertex_id += 1) {

                bool in_submesh = submesh.firstVertex <= vertex_id && vertex_id <= submesh.firstVertex + submesh.vertexCount;
                var role = in_submesh ? Role.Unassigned : Role.NotBlock;

                // Use the first bone with a role ; unity gives bones by decreasing weights so this should be ok even for non robotic stuff.
                var iterator_end = bone_weight_iterator + bone_per_vertex[vertex_id];
                for (; bone_weight_iterator < iterator_end; bone_weight_iterator += 1) {
                    if (role != Role.Unassigned) {
                        // Already assigned
                        bone_weight_iterator = iterator_end;
                        break;
                    }
                    int bone_id = bone_weights[bone_weight_iterator].boneIndex;
                    role = role_for_bone[bone_id];
                }
                roles[vertex_id] = role;
            }

            // Some debug statistics
            var vertex_counts = roles.GroupBy(role => role).ToDictionary(group => group.Key, group => group.Count());
            Debug.Log($"Role vertex counts: {string.Join(", ", vertex_counts.ToArray())}");
            
            return roles;
        }

        static private Vector3[] vertex_positions_for_animation(Mesh mesh, int block_submesh) {
            // For animations, it is better to use triangle center coordinates instead of a random vertex.
            // Especially for arm cut which is precise.
            // This function returns an array[vertex_id] = barycenter of triangle the vertex is part of.
            //
            // This is ambiguous for triangles sharing vertices, so this is only computed for the replicator block submesh
            Vector3[] vertices = mesh.vertices;
            int[] triangle_indexes = mesh.GetTriangles(block_submesh);
            for (int i = 0; i < triangle_indexes.Length; i += 3) {
                int a = triangle_indexes[i];
                int b = triangle_indexes[i + 1];
                int c = triangle_indexes[i + 2];
                Vector3 barycenter = 1f/3f * (vertices[a] + vertices[b] + vertices[c]);
                vertices[a] = barycenter;
                vertices[b] = barycenter;
                vertices[c] = barycenter;
            }
            return vertices;
        }

        private struct LimbAxisReferential {
            private Vector3 origin_os;
            private Vector3 axis_os;
            private float scale_factor;

            public LimbAxisReferential(VRCContactReceiver proximity, Transform mesh_transform) {
                Debug.Assert(proximity.shapeType == VRCContactReceiver.ShapeType.Sphere);
                Debug.Assert(proximity.receiverType == VRCContactReceiver.ReceiverType.Proximity);

                var contact_ws = proximity.transform.position + proximity.transform.TransformVector(proximity.position);
                origin_os = mesh_transform.InverseTransformPoint(contact_ws);

                var axis_radius_local = Vector3.up * proximity.radius; // up is the green one, pointing towards +1.
                var axis_radius_os = mesh_transform.InverseTransformVector(proximity.transform.TransformVector(axis_radius_local));
                axis_os = axis_radius_os.normalized;
                scale_factor = axis_radius_os.magnitude;
            }

            public float axis_coordinate(Vector3 position_os) {
                float r = Vector3.Dot(axis_os, position_os - origin_os) / scale_factor;
                Debug.Assert(-1f <= r && r <= 1f);
                return r;
            }
        };
    }
}
#endif