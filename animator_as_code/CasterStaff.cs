#if UNITY_EDITOR
using AnimatorAsCode.V1;
using AnimatorAsCode.V1.ModularAvatar;
using nadena.dev.ndmf;
using nadena.dev.modular_avatar.core;
using UnityEditor;
using UnityEngine;
using VRC.SDK3.Avatars.Components;
using VRC.SDK3.Avatars.ScriptableObjects;
using VRC.SDKBase;
using VRC.SDK3.Dynamics.Constraint.Components;
using AnimatorAsCode.V1.VRC;
using System.Collections.Generic;

[assembly: ExportsPlugin(typeof(Lereldarion.CasterStaffPlugin))]

namespace Lereldarion {
    public class CasterStaff : MonoBehaviour, IEditorOnly {
        public VRCExpressionsMenu MenuTarget;

        [Header("Staff objects")]
        public GameObject StaffContainer;
        public Renderer Staff;
        public Renderer Surface;
        public GameObject StaffContacts;
        public VRCRaycast Raycast;

        [Header("Overlays")]
        public Material OverlayNormals;
        public Material OverlayWireframe;
        public Material OverlayGrid;
        public Material OverlayHUD;
        public Material OverlayDebugLighting;
        public Material TrailNormals;
        public Material TrailWireframe;
        public Material TrailGrid;
        public Material TrailHUD;
        public Material TrailDebugLighting;

    }

    public class CasterStaffPlugin : Plugin<CasterStaffPlugin> {
        public override string DisplayName => "Caster Staff Animator";

        public string SystemName => "CasterStaff";

        protected override void Configure() {
            InPhase(BuildPhase.Generating).Run(DisplayName, Generate);
        }

        // Position of staff
        private enum Position { Storage, OneHanded, TwoHanded, World }

        // Active Effect
        private enum Effect {
            None,
            // Overlays
            Normals, Wireframe, WorldGrid, HUD, DebugLighting,
            // Others
            //Card // TODO
        }


        private struct EffectConfig
        {
            public Vector4 emission_ST;
            public System.Func<CasterStaff, Material> material;
            public System.Func<CasterStaff, Material> trail; // Returns a null if not capable of trail
            public bool can_sphere; // Is fake-sphere capable, and thus can be grabbed and moved around (Hand, Raycast, Staff modes)
            public bool dissolve; // Has a dissolve on the edges
        };
        private Dictionary<Effect, EffectConfig> effect_config = new Dictionary<Effect, EffectConfig> {
            // Emission0 uv (tiling, offset) for respective effect icon, on staff material (poiyomi)
            {Effect.None, new EffectConfig{ emission_ST = new Vector4(0.5f, 0.5f, 0.72f, -0.2f), material = c => null, trail = c => null, can_sphere = false, dissolve = false }},
            
            {Effect.Normals, new EffectConfig{ emission_ST = new Vector4(1f, 1f, -0.23f, -0.04f), material = c => c.OverlayNormals, trail = c => c.TrailNormals, can_sphere = true, dissolve = true }},
            {Effect.Wireframe, new EffectConfig{ emission_ST = new Vector4(1f, 1f, -0.08f, -0.17f), material = c => c.OverlayWireframe, trail = c => c.TrailWireframe, can_sphere = true, dissolve = true }},
            {Effect.WorldGrid, new EffectConfig{ emission_ST = new Vector4(1f, 1f, 0f, -0.36f), material = c => c.OverlayGrid, trail = c => c.TrailGrid, can_sphere = true, dissolve = false }},
            {Effect.HUD, new EffectConfig{ emission_ST = new Vector4(1f, 1f, -0.02f, -0.57f), material = c => c.OverlayHUD, trail = c => c.TrailHUD, can_sphere = true, dissolve = false }},
            {Effect.DebugLighting, new EffectConfig{ emission_ST = new Vector4(1f, 1f, -0.14f, -0.75f), material = c => c.OverlayDebugLighting, trail = c => c.TrailDebugLighting, can_sphere = true, dissolve = false }},

            //{Effect.Card, new Vector4(1f, 1f, 0.35f, -0.04f)},
        };

        // Target of effect (where the effect mesh is). Overlays use all 4, other effects may not.
        private enum Target { Window, Hand, Staff, Raycast }

        private Color emissive_cyan = new Color(0f, 1.3f, 1.4f, 1f);
        private Color emissive_red = new Color(1.2f, 0f, 0f, 1f);

        private void Generate(BuildContext ctx) {
            var config = ctx.AvatarRootTransform.GetComponentInChildren<CasterStaff>(true);
            if(config == null) { return; }

            var aac = AacV1.Create(new AacConfiguration {
                SystemName = SystemName,
                AnimatorRoot = ctx.AvatarRootTransform,
                DefaultValueRoot = ctx.AvatarRootTransform,
                AssetKey = GUID.Generate().ToString(),
                AssetContainer = ctx.AssetContainer,
                ContainerMode = AacConfiguration.Container.OnlyWhenPersistenceRequired,
                DefaultsProvider = new AacDefaultsProvider()
            });

            var ma_object = new GameObject(SystemName) { transform = { parent = ctx.AvatarRootTransform }};
            var ma = MaAc.Create(ma_object);
            MaacMenuItem new_installed_menu_item() {
                var menu = new GameObject { transform = { parent = ma_object.transform }};
                var installer = menu.AddComponent<ModularAvatarMenuInstaller>();
                installer.installTargetMenu = config.MenuTarget;
                return ma.EditMenuItem(menu);
            }
            var ctrl = aac.NewAnimatorController();

            int position_enum_count = System.Enum.GetValues(typeof(Position)).Length;
            int effect_enum_count = System.Enum.GetValues(typeof(Effect)).Length;
            int target_enum_count = System.Enum.GetValues(typeof(Target)).Length;
            Debug.Assert(position_enum_count * effect_enum_count * target_enum_count <= 255);
            int state_int(Position p, Effect e, Target t) => ((int) p * effect_enum_count + (int) e) * target_enum_count + (int) t;
            
            AacFlLayer layer = ctrl.NewLayer("Staff");
            AacFlIntParameter synced = layer.IntParameter("Staff/Synced");
            ma.NewParameter(synced).WithDefaultValue(state_int(Position.Storage, Effect.None, Target.Window));

            // Menu deploy. Driven, or used to force to storage (if deployed) or 1-hand (if storage).
            AacFlBoolParameter menu_deploy = layer.BoolParameter("Staff/MenuDeploy");
            ma.NewParameter(menu_deploy).WithDefaultValue(false).NotSaved().NotSynced();
            new_installed_menu_item().Name("Deploy Staff").Toggle(menu_deploy);

            // Contacts
            AacFlBoolParameter staff_storage_contact = layer.BoolParameter("Staff/StorageContact");
            AacFlBoolParameter staff_shaft_left_hand_contact = layer.BoolParameter("Staff/ShaftLeftHandContact");
            AacFlBoolParameter staff_shaft_right_hand_contact = layer.BoolParameter("Staff/ShaftRightHandContact");

            var effect_contacts = new Dictionary<Effect, AacFlBoolParameter>();
            foreach (Effect e in System.Enum.GetValues(typeof(Effect))) {
                effect_contacts.Add(e, layer.BoolParameter($"Staff/Effect/{e}Contact"));
            }

            // Staff constraints. Parent + scale : [storage, left hand]
            var staff_parent_constraint = config.StaffContainer.GetComponent<VRCParentConstraint>();
            var staff_scale_constraint = config.StaffContainer.GetComponent<VRCScaleConstraint>();
            var staff_aim_constraint = config.StaffContainer.GetComponent<VRCAimConstraint>();
            var surface_parent_constraint = config.Surface.GetComponent<VRCParentConstraint>();

            var surface_scale_by_target = new Dictionary<Target, Vector3>{
                { Target.Window, new Vector3(0.001f, 1f, 1f) },
                { Target.Hand, Vector3.one * 0.8f },
                { Target.Staff, Vector3.one * 25f },
                { Target.Raycast, Vector3.one * 25f },
            };
            Target[] supported_targets_for_effect(Effect e) {
                if(effect_config[e].can_sphere) return (Target[]) System.Enum.GetValues(typeof(Target));
                else return new Target[] { Target.Window };
            }

            // Entry point. Used on animator start/resume.
            var init_state = layer.NewState("Init");

            // Define steady states, and keep references in a table for adding transitions later
            var steady_states = new Dictionary<(Position, Effect, Target), AacFlState>();
            foreach(Position p in System.Enum.GetValues(typeof(Position))) {
                foreach(Effect e in System.Enum.GetValues(typeof(Effect))) {
                    EffectConfig econfig = effect_config[e];
                    foreach(Target t in supported_targets_for_effect(e)) {                        
                        AacFlState state = layer.NewState($"{p}@{e}@{t}");
                        AacFlClip clip = aac.NewClip($"steady_{p}@{e}@{t}");
                        state.Drives(synced, state_int(p, e, t));
                        state.Drives(menu_deploy, p != Position.Storage);
                        state.DrivingLocally();
                        state.WithAnimation(clip);
                        steady_states.Add((p, e, t), state);

                        // Position
                        clip.Toggling(config.StaffContacts, p != Position.Storage);
                        clip.Animating(SetConstraintActiveSource(staff_parent_constraint, p == Position.Storage ? 0 : 1));
                        clip.Animating(SetConstraintActiveSource(staff_scale_constraint, p == Position.Storage ? 0 : 1));
                        clip.Animating(SetConstraintWorldFixed(staff_parent_constraint, p == Position.World));
                        clip.TogglingComponent(staff_aim_constraint, p == Position.TwoHanded);
                        clip.Animating(edit => edit.Animates(config.Staff, "material._DissolveAlpha_Staff").WithOneFrame(0f)); // Only used during deploy/store animations

                        // Effect
                        clip.Toggling(config.Surface.gameObject, e != Effect.None);
                        if(e != Effect.None) {
                            clip.SwappingMaterial(config.Surface, 0, econfig.material(config));
                        }

                        // Target
                        clip.Scaling(config.Surface.transform, surface_scale_by_target[t]);
                        clip.TogglingComponent(config.Raycast, t != Target.Raycast);
                        clip.Animating(SetConstraintActiveSource(surface_parent_constraint, (int) t)); // Constraint set to the right order
                    }
                }
            }

            // Init
            foreach(Effect e in System.Enum.GetValues(typeof(Effect))) {
                var default_state_for_effect = steady_states[(Position.Storage, e, Target.Window)];
                foreach(Position p in System.Enum.GetValues(typeof(Position))) {
                    foreach(Target t in supported_targets_for_effect(e)) {
                        int synced_value = state_int(p, e, t);

                        // Remote : load avatar, or enter culling range. Go to synced state.
                        // TODO this will not handle world drops well (Position.World / Target.Raycast). What to do in this case ?
                        init_state.TransitionsTo(steady_states[(p, e, t)]).When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(synced_value));

                        // Local : avatar init. Keep Effect, reset position and target.
                        init_state.TransitionsTo(default_state_for_effect).When(layer.Av3().ItIsLocal()).And(synced.IsEqualTo(synced_value));
                    }
                }
            }

            // Position transitions
            foreach(Effect e in System.Enum.GetValues(typeof(Effect))) {
                foreach(Target t in supported_targets_for_effect(e)) {
                    var storage = steady_states[(Position.Storage, e, t)];
                    var one_handed = steady_states[(Position.OneHanded, e, t)];
                    var two_handed = steady_states[(Position.TwoHanded, e, t)];
                    var world = steady_states[(Position.TwoHanded, e, t)];

                    AacFlState deploy = layer.NewState($"Deploy@{e}@{t}");
                    deploy.Drives(synced, state_int(Position.OneHanded, e, t)).DrivingLocally(); // Early sync
                    deploy.WithAnimation(aac.NewClip()
                        // Immediate 1-hand
                        .TogglingComponent(staff_aim_constraint, false)
                        .Animating(SetConstraintActiveSource(staff_parent_constraint, 1))
                        .Animating(SetConstraintActiveSource(staff_scale_constraint, 1))
                        .Animating(SetConstraintWorldFixed(staff_parent_constraint, false))
                        // Dissolve
                        .Animating(edit => edit.Animates(config.Staff, "material._DissolveAlpha_Staff").WithSecondsUnit(curve => curve.Linear(0f, 1f).Linear(0.5f, 0f)))
                        .Toggling(config.Surface.gameObject, false) // Temporary disable surface
                    );
                    deploy.AutomaticallyMovesTo(one_handed);

                    AacFlState store = layer.NewState($"Store@{e}@{t}"); // Store from any position.
                    store.Drives(synced, state_int(Position.Storage, e, t)).DrivingLocally(); // Early sync
                    store.WithAnimation(aac.NewClip()
                        // Dissolve only, followed by instant Storage. Do not relocate, so we can reuse the previous constraint state
                        .Animating(edit => edit.Animates(config.Staff, "material._DissolveAlpha_Staff").WithSecondsUnit(curve => curve.Linear(0f, 0f).Linear(0.5f, 1f)))
                        .Toggling(config.StaffContacts, false) // Early contact disable
                        .Toggling(config.Surface.gameObject, false) // Temporary disable surface
                    );
                    store.AutomaticallyMovesTo(storage);

                    storage.TransitionsTo(deploy).When(layer.Av3().ItIsLocal()).And(staff_storage_contact.IsTrue()).And(layer.Av3().GestureLeft.IsEqualTo(AacAv3.Av3Gesture.Fist));
                    one_handed.TransitionsTo(store).When(layer.Av3().ItIsLocal()).And(staff_storage_contact.IsTrue()).And(layer.Av3().GestureLeft.IsEqualTo(AacAv3.Av3Gesture.HandOpen));

                    storage.TransitionsTo(deploy).When(layer.Av3().ItIsLocal()).And(menu_deploy.IsTrue());
                    one_handed.TransitionsTo(store).When(layer.Av3().ItIsLocal()).And(menu_deploy.IsFalse());

                    one_handed.TransitionsTo(store).When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_int(Position.Storage, e, t)));
                    storage.TransitionsTo(deploy).When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_int(Position.OneHanded, e, t)));

                    // Two hands
                    one_handed.TransitionsTo(two_handed).When(layer.Av3().ItIsLocal()).And(staff_shaft_right_hand_contact.IsTrue()).And(layer.Av3().GestureRight.IsEqualTo(AacAv3.Av3Gesture.Fist));
                    two_handed.TransitionsTo(one_handed).When(layer.Av3().ItIsLocal()).And(layer.Av3().GestureRight.IsEqualTo(AacAv3.Av3Gesture.HandOpen));

                    two_handed.TransitionsTo(store).When(layer.Av3().ItIsLocal()).And(menu_deploy.IsFalse());
                    two_handed.TransitionsTo(store).When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_int(Position.Storage, e, t)));

                    one_handed.TransitionsTo(two_handed).When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_int(Position.TwoHanded, e, t)));
                    two_handed.TransitionsTo(one_handed).When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_int(Position.OneHanded, e, t)));

                    // World drop
                    one_handed.TransitionsTo(world).When(layer.Av3().ItIsLocal()).And(layer.Av3().GestureLeft.IsEqualTo(AacAv3.Av3Gesture.HandOpen));
                    world.TransitionsTo(one_handed).When(layer.Av3().ItIsLocal()).And(staff_shaft_left_hand_contact.IsTrue()).And(layer.Av3().GestureLeft.IsEqualTo(AacAv3.Av3Gesture.Fist));
                    
                    world.TransitionsTo(store).When(layer.Av3().ItIsLocal()).And(menu_deploy.IsFalse());
                    world.TransitionsTo(store).When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_int(Position.Storage, e, t)));

                    one_handed.TransitionsTo(world).When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_int(Position.World, e, t)));
                    world.TransitionsTo(one_handed).When(layer.Av3().ItIsRemote()).And(synced.IsNotEqualTo(state_int(Position.OneHanded, e, t)));
                }
            }

            // Fallback synced transitions : all previous transitions were local (follow 1 step from master).
            // In case of desync, just resets the remote through init.
            // Always define last to let the nice transitions take priority.
            foreach(Effect e in System.Enum.GetValues(typeof(Effect))) {
                foreach(Position p in System.Enum.GetValues(typeof(Position))) {
                    foreach(Target t in supported_targets_for_effect(e)) {
                        steady_states[(p, e, t)].TransitionsTo(init_state).When(layer.Av3().ItIsRemote()).And(synced.IsNotEqualTo(state_int(p, e, t)));
                    }
                }
            }

            ma.NewMergeAnimator(ctrl.AnimatorController, VRCAvatarDescriptor.AnimLayerType.FX);

            {
                // Make surface bounding box square. Important for culling of fake sphere mode.
                // Change the mesh itself to have it persist in the uploaded prefabs.
                Mesh surface_mesh = config.Surface.GetComponent<MeshFilter>().sharedMesh;
                Bounds bbox = surface_mesh.bounds;
                Vector3 bbox_size = bbox.size;
                float max = Mathf.Max(bbox_size.x, Mathf.Max(bbox_size.y, bbox_size.z));
                surface_mesh.bounds = new Bounds(bbox.center, max * Vector3.one);
            }
        }

        //////////////////////////////////////////////////////////////////////////////////////////////////////////////////

        // Most constraint animations have only one source active at a time. Provide a quick setter for that.
        static private System.Action<AacFlEditClip> SetConstraintActiveSource(VRCParentConstraint constraint, int active_source) {
            return clip => {
                for (int i = 0; i < constraint.Sources.Count; i += 1) {
                    clip.Animates(constraint, $"Sources.source{i}.Weight").WithOneFrame(i == active_source ? 1 : 0);
                }
            };
        }
        static private System.Action<AacFlEditClip> SetConstraintActiveSource(VRCScaleConstraint constraint, int active_source) {
            return clip => {
                for (int i = 0; i < constraint.Sources.Count; i += 1) {
                    clip.Animates(constraint, $"Sources.source{i}.Weight").WithOneFrame(i == active_source ? 1 : 0);
                }
            };
        }

        static private System.Action<AacFlEditClip> SetConstraintWorldFixed(VRCParentConstraint constraint, bool fixed_to_world) {
            return clip => {
                clip.Animates(constraint, "FreezeToWorld").WithOneFrame(fixed_to_world ? 1 : 0);
            };
        }

    }
}
#endif