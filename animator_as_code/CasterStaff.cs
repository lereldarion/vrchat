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
using UnityEditorInternal;
using BestHTTP.SecureProtocol.Org.BouncyCastle.Crypto.Paddings;

[assembly: ExportsPlugin(typeof(Lereldarion.CasterStaffPlugin))]

namespace Lereldarion {
    public class CasterStaff : MonoBehaviour, IEditorOnly {
        public VRCExpressionsMenu MenuTarget;

        [Header("Staff objects")]
        public GameObject StaffContainer;
        public Renderer Staff;
        public Renderer Surface;
        public GameObject StaffContacts;
        public VRCRaycast Raycaster;
        public Transform RaycastAnchor;
        public TrailRenderer Trail;

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
    }

    public class CasterStaffPlugin : Plugin<CasterStaffPlugin> {
        public override string DisplayName => "Caster Staff Animator";

        public string SystemName => "CasterStaff";

        protected override void Configure() {
            InPhase(BuildPhase.Generating).Run(DisplayName, Generate);
        }

        // Position of staff. Trail is equivalent to Storage but with trail active.
        private enum Position { Storage, OneHanded, TwoHanded, World, Trail }

        // Active Effect
        private enum Effect {
            None,
            // Overlays
            Normals, Wireframe, WorldGrid, HUD, DebugLighting,
            // Others
            //Card // TODO
        }

        // Target of effect (where the effect mesh is). Overlays use all 4, other effects may not.
        private enum Target { Window, Hand, Staff, Raycast }

        private struct EffectConfig
        {
            public Vector4 EmissionST;
            public System.Func<CasterStaff, Material> Material;
            public System.Func<CasterStaff, Material> Trail; // Returns a null if not capable of trail
            public bool CanSphere; // Is fake-sphere capable, and thus can be grabbed and moved around (Hand, Raycast, Staff modes)
            public bool HasDissolve; // Has a dissolve on the edges
        };
        private Dictionary<Effect, EffectConfig> effect_config = new Dictionary<Effect, EffectConfig> {
            // Emission0 uv (tiling, offset) for respective effect icon, on staff material (poiyomi)
            {Effect.None, new EffectConfig{ EmissionST = new Vector4(0.5f, 0.5f, 0.72f, -0.2f), Material = c => null, Trail = c => null, CanSphere = false, HasDissolve = false }},
            
            {Effect.Normals, new EffectConfig{ EmissionST = new Vector4(1f, 1f, -0.23f, -0.04f), Material = c => c.OverlayNormals, Trail = c => c.TrailNormals, CanSphere = true, HasDissolve = true }},
            {Effect.Wireframe, new EffectConfig{ EmissionST = new Vector4(1f, 1f, -0.08f, -0.17f), Material = c => c.OverlayWireframe, Trail = c => c.TrailWireframe, CanSphere = true, HasDissolve = true }},
            {Effect.WorldGrid, new EffectConfig{ EmissionST = new Vector4(1f, 1f, 0f, -0.36f), Material = c => c.OverlayGrid, Trail = c => c.TrailGrid, CanSphere = true, HasDissolve = false }},
            {Effect.HUD, new EffectConfig{ EmissionST = new Vector4(1f, 1f, -0.02f, -0.57f), Material = c => c.OverlayHUD, Trail = c => c.TrailHUD, CanSphere = true, HasDissolve = false }},
            {Effect.DebugLighting, new EffectConfig{ EmissionST = new Vector4(1f, 1f, -0.14f, -0.75f), Material = c => c.OverlayDebugLighting, Trail = c => null, CanSphere = true, HasDissolve = false }},

            //{Effect.Card, new Vector4(1f, 1f, 0.35f, -0.04f)},
        };
        private struct TargetConfig
        {
            public Vector3 SurfaceScale;
            public Vector4 Dissolve; // For overlays with border dissolve support, steady state config : (radius, border width, scale, time scale)
            readonly public float DissolvedRadius => Dissolve.y > 0 ? 0f : 1f - Dissolve.y;
        };
        private Dictionary<Target, TargetConfig> target_config = new Dictionary<Target, TargetConfig>{
            { Target.Window, new TargetConfig { SurfaceScale = new Vector3(0.001f, 1f, 1f), Dissolve = new Vector4(0f, -0.2f, 1f, -0.1f) } },
            { Target.Hand, new TargetConfig { SurfaceScale = Vector3.one * 0.8f, Dissolve = new Vector4(0.8f, 0.2f, 0.8f, 0.1f) } },
            { Target.Staff, new TargetConfig { SurfaceScale = Vector3.one * 12f, Dissolve = new Vector4(0.8f, 0.2f, 2f, 0.1f) } },
            { Target.Raycast, new TargetConfig { SurfaceScale = Vector3.one * 12f, Dissolve = new Vector4(0.8f, 0.2f, 2f, 0.1f) } },
        };
        private Color emissive_cyan = new Color(0f, 1.3f, 1.4f, 1f);
        private Color emissive_red = new Color(1.2f, 0f, 0f, 1f);

        private void Generate(BuildContext ctx) {
            CasterStaff config = ctx.AvatarRootTransform.GetComponentInChildren<CasterStaff>(true);
            if(config == null) { return; }

            AacFlBase aac = AacV1.Create(new AacConfiguration {
                SystemName = SystemName,
                AnimatorRoot = ctx.AvatarRootTransform,
                DefaultValueRoot = ctx.AvatarRootTransform,
                AssetKey = GUID.Generate().ToString(),
                AssetContainer = ctx.AssetContainer,
                ContainerMode = AacConfiguration.Container.OnlyWhenPersistenceRequired,
                DefaultsProvider = new AacDefaultsProvider()
            });

            GameObject ma_object = new GameObject(SystemName) { transform = { parent = ctx.AvatarRootTransform }};
            MaAc ma = MaAc.Create(ma_object);
            MaacMenuItem new_installed_menu_item() {
                var menu = new GameObject { transform = { parent = ma_object.transform }};
                var installer = menu.AddComponent<ModularAvatarMenuInstaller>();
                installer.installTargetMenu = config.MenuTarget;
                return ma.EditMenuItem(menu);
            }
            AacFlController animator_controller = aac.NewAnimatorController();
            
            AacFlLayer layer = animator_controller.NewLayer("Staff");
            AacFlIntParameter synced = layer.IntParameter("Staff/Synced");
            MaacParameter<int> ma_synced = ma.NewParameter(synced);

            // Menu deploy. Driven, or used to force to storage (if deployed) or 1-hand (if storage).
            AacFlBoolParameter menu_deploy = layer.BoolParameter("Staff/MenuDeploy");
            ma.NewParameter(menu_deploy).WithDefaultValue(false).NotSaved().NotSynced();
            new_installed_menu_item().Name("Deploy Staff").Toggle(menu_deploy);

            // Inputs : Contacts and raycast info
            AacFlBoolParameter staff_storage_contact = layer.BoolParameter("Staff/StorageContact");
            AacFlBoolParameter staff_shaft_left_hand_contact = layer.BoolParameter("Staff/ShaftLeftHandContact");
            AacFlBoolParameter staff_shaft_right_hand_contact = layer.BoolParameter("Staff/ShaftRightHandContact");
            AacFlBoolParameter main_ring_contact = layer.BoolParameter("Staff/MainRingContact");
            AacFlBoolParameter aoe_ring_contact = layer.BoolParameter("Staff/AoeRingContact");
            AacFlBoolParameter raycast_hit = layer.BoolParameter("Staff/Raycast_Hit");
            AacFlBoolParameter trail_contact = layer.BoolParameter("Staff/TrailContact");

            var effect_contacts = new Dictionary<Effect, AacFlBoolParameter>();
            foreach (Effect e in System.Enum.GetValues(typeof(Effect))) {
                effect_contacts.Add(e, layer.BoolParameter($"Staff/Effect/{e}Contact"));
            }

            // Constraints
            var staff_parent_constraint = config.StaffContainer.GetComponent<VRCParentConstraint>(); // [storage, left hand]
            var staff_scale_constraint = config.StaffContainer.GetComponent<VRCScaleConstraint>(); // [storage, left hand]
            var staff_aim_constraint = config.StaffContainer.GetComponent<VRCAimConstraint>(); // Toggled on/off
            var surface_parent_constraint = config.Surface.GetComponent<VRCParentConstraint>(); // 4 targets in order
            var raycaster_parent_constraint = config.Raycaster.GetComponent<VRCParentConstraint>(); // Locks raycaster to head, toggle world drop

            // Entry point. Used on animator start/resume.
            var init_state = layer.NewState("Init");

            // Define steady states and their ids. Keep references in a table for adding transitions later.
            var steady_states = new Dictionary<(Position, Effect, Target), AacFlState>();
            var state_id = new Dictionary<(Position, Effect, Target), int>();
            foreach(Effect e in System.Enum.GetValues(typeof(Effect))) {
                EffectConfig e_config = effect_config[e];
                Material trail_material = e_config.Trail(config);
                foreach(Position p in System.Enum.GetValues(typeof(Position))) {
                    if(trail_material is null && p == Position.Trail) continue; // No trail mode if unsupported by effect
                    foreach(Target t in System.Enum.GetValues(typeof(Target))) {
                        if(!e_config.CanSphere && t != Target.Window) break; // Other targets require sphere mode capability

                        AacFlState state = layer.NewState($"{p}@{e}@{t}");
                        int id = steady_states.Count;
                        steady_states.Add((p, e, t), state);
                        state_id.Add((p, e, t), id);

                        state.Drives(synced, id);
                        state.Drives(menu_deploy, p != Position.Storage);
                        state.DrivingLocally();

                        AacFlClip clip = aac.NewClip($"steady_{p}@{e}@{t}");
                        state.WithAnimation(clip);

                        // Position
                        bool is_in_storage = p == Position.Storage || p == Position.Trail;
                        clip.Toggling(config.StaffContacts, !is_in_storage);
                        clip.Animating(SetConstraintActiveSource(staff_parent_constraint, is_in_storage ? 0 : 1));
                        clip.Animating(SetConstraintActiveSource(staff_scale_constraint, is_in_storage ? 0 : 1));
                        clip.Animating(SetConstraintWorldFixed(staff_parent_constraint, p == Position.World));
                        clip.TogglingComponent(staff_aim_constraint, p == Position.TwoHanded);
                        clip.Animating(edit => edit.Animates(config.Staff, "material._DissolveAlpha_Staff").WithOneFrame(0f)); // Only used during deploy/store animations

                        // Effect
                        clip.TogglingComponent(config.Surface, e != Effect.None);
                        if(e != Effect.None) {
                            clip.SwappingMaterial(config.Surface, 0, e_config.Material(config));
                        }
                        clip.Animating(SetVector4(config.Staff, "material._EmissionMask_Staff_ST", e_config.EmissionST));

                        // Trail. TODO add secondary layer that toggles off the renderer after timeout + blendtree for avatar scaling. World drop parent constraint too ?
                        clip.Animating(edit => edit.Animates(config.Trail, "m_Emitting").WithOneFrame(p == Position.Trail ? 1f : 0f));
                        if(p == Position.Trail) {
                            clip.SwappingMaterial(config.Trail, 0, trail_material);
                        }

                        // Target
                        TargetConfig t_config = target_config[t];
                        clip.Scaling(config.Surface.transform, t_config.SurfaceScale);
                        clip.Animating(SetConstraintActiveSource(surface_parent_constraint, (int) t)); // Constraint set to the right order
                        clip.Animating(SetConstraintWorldFixed(raycaster_parent_constraint, t == Target.Raycast));
                        clip.Animating(edit => {
                            edit.AnimatesColor(config.Staff, "material._EmissionColor_Staff").WithOneFrame(t == Target.Raycast ? emissive_red : emissive_cyan);
                            edit.Animates(config.Staff, "material._EmissionStrength1_Staff").WithOneFrame(t == Target.Staff ? 1f : 0f);
                        });
                        if(e_config.HasDissolve) {
                            clip.Animating(SetVector4(config.Surface, "material._Overlay_Border_Dissolve_Config", t_config.Dissolve));
                        }
                    }
                }
            }

            Debug.Assert(steady_states.Count <= 255);
            ma_synced.WithDefaultValue(state_id[(Position.Storage, Effect.None, Target.Window)]);

            // Init
            foreach(Effect e in System.Enum.GetValues(typeof(Effect))) {
                var default_state_for_effect = steady_states[(Position.Storage, e, Target.Window)];
                foreach(Position p in System.Enum.GetValues(typeof(Position))) {
                    foreach(Target t in System.Enum.GetValues(typeof(Target))) {
                        if(!steady_states.TryGetValue((p, e, t), out AacFlState steady_state)) continue;
                        int synced_value = state_id[(p, e, t)];

                        // Remote : load avatar, or enter culling range. Go to synced state.
                        // World drops wil not late sync nicely, so just ignore them.
                        if(p != Position.World && t != Target.Raycast) {
                            init_state.TransitionsTo(steady_state).When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(synced_value));
                        }

                        // Local : avatar init. Keep Effect, reset position and target.
                        init_state.TransitionsTo(default_state_for_effect).When(layer.Av3().ItIsLocal()).And(synced.IsEqualTo(synced_value));
                    }
                }
            }

            // Position transitions.
            foreach(Effect e in System.Enum.GetValues(typeof(Effect))) {
                EffectConfig e_config = effect_config[e];
                foreach(Target t in System.Enum.GetValues(typeof(Target))) {
                    if(!steady_states.TryGetValue((Position.Storage, e, t), out AacFlState storage)) continue;
                    AacFlState one_handed = steady_states[(Position.OneHanded, e, t)];
                    AacFlState two_handed = steady_states[(Position.TwoHanded, e, t)];
                    AacFlState world = steady_states[(Position.World, e, t)];
                    TargetConfig t_config = target_config[t];

                    // OneHanded
                    AacFlState deploy = layer.NewState($"Deploy@{e}@{t}");
                    deploy.Drives(synced, state_id[(Position.OneHanded, e, t)]).DrivingLocally(); // Early sync
                    {
                        AacFlClip clip = aac.NewClip();
                        deploy.WithAnimation(clip);
                        // Immediate 1-hand
                        clip.TogglingComponent(staff_aim_constraint, false);
                        clip.Animating(SetConstraintActiveSource(staff_parent_constraint, 1));
                        clip.Animating(SetConstraintActiveSource(staff_scale_constraint, 1));
                        clip.Animating(SetConstraintWorldFixed(staff_parent_constraint, false));
                        // Un-Dissolve
                        clip.Animating(edit => edit.Animates(config.Staff, "material._DissolveAlpha_Staff").WithSecondsUnit(keys => keys.Linear(0f, 1f).Linear(0.5f, 0f)));
                        if(t != Target.Raycast) {
                            // Animate effect, dissolve or not
                            if (e_config.HasDissolve) {
                                clip.Animating(edit => edit.Animates(config.Surface, "material._Overlay_Border_Dissolve_Config.x").WithSecondsUnit(keys => {
                                    keys.Linear(0f, t_config.DissolvedRadius);
                                    keys.Linear(0.5f, t_config.DissolvedRadius); // End of staff un-dissolve
                                    keys.Linear(1f, t_config.Dissolve.x);
                                }));
                                // yzw already set from steady state, and target does not change
                            } else {
                                clip.TogglingComponent(config.Surface, false); // Temporary disable surface
                            }
                        }
                    }
                    deploy.AutomaticallyMovesTo(one_handed);

                    AacFlState store = layer.NewState($"Store@{e}@{t}");
                    store.Drives(synced, state_id[(Position.Storage, e, t)]).DrivingLocally(); // Early sync
                    {
                        // Dissolve staff, maybe effect before. Then instant transition that relocate to storage.
                        // In case of raycast, keep it unchanged. A weird possible config using menu deploy with stored staff and raycast left in the world.
                        AacFlClip clip = aac.NewClip();
                        store.WithAnimation(clip);
                        clip.Toggling(config.StaffContacts, false); // Early contact disable
                        if(e_config.HasDissolve && t != Target.Raycast) {
                            clip.Animating(edit => {
                                edit.Animates(config.Staff, "material._DissolveAlpha_Staff").WithSecondsUnit(keys => keys.Linear(0f, 0f).Linear(0.2f, 0f).Linear(0.7f, 1f));
                                edit.Animates(config.Surface, "material._Overlay_Border_Dissolve_Config.x").WithSecondsUnit(keys => {
                                    keys.Linear(0f, t_config.Dissolve.x);
                                    keys.Linear(0.2f, t_config.DissolvedRadius);
                                });
                            });
                        } else {
                            if(t != Target.Raycast) clip.TogglingComponent(config.Surface, false); // Temporary disable surface
                            clip.Animating(edit => edit.Animates(config.Staff, "material._DissolveAlpha_Staff").WithSecondsUnit(keys => keys.Linear(0f, 0f).Linear(0.5f, 1f)));
                        }
                    }
                    store.AutomaticallyMovesTo(storage);

                    storage.TransitionsTo(deploy)
                    .When(layer.Av3().ItIsLocal()).And(staff_storage_contact.IsTrue()).And(layer.Av3().GestureLeft.IsEqualTo(AacAv3.Av3Gesture.Fist))
                    .Or().When(layer.Av3().ItIsLocal()).And(menu_deploy.IsTrue())
                    .Or().When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_id[(Position.OneHanded, e, t)]));

                    one_handed.TransitionsTo(store)
                    .When(layer.Av3().ItIsLocal()).And(staff_storage_contact.IsTrue()).And(layer.Av3().GestureLeft.IsEqualTo(AacAv3.Av3Gesture.HandOpen))
                    .Or().When(layer.Av3().ItIsLocal()).And(menu_deploy.IsFalse())
                    .Or().When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_id[(Position.Storage, e, t)]));

                    // Two hands
                    one_handed.TransitionsTo(two_handed)
                    .When(layer.Av3().ItIsLocal()).And(staff_shaft_right_hand_contact.IsTrue()).And(layer.Av3().GestureRight.IsEqualTo(AacAv3.Av3Gesture.Fist))
                    .Or().When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_id[(Position.TwoHanded, e, t)]));

                    two_handed.TransitionsTo(one_handed)
                    .When(layer.Av3().ItIsLocal()).And(layer.Av3().GestureRight.IsEqualTo(AacAv3.Av3Gesture.HandOpen))
                    .Or().When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_id[(Position.OneHanded, e, t)]));

                    two_handed.TransitionsTo(store)
                    .When(layer.Av3().ItIsLocal()).And(menu_deploy.IsFalse())
                    .Or().When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_id[(Position.Storage, e, t)]));

                    // World drop
                    one_handed.TransitionsTo(world)
                    .When(layer.Av3().ItIsLocal()).And(layer.Av3().GestureLeft.IsEqualTo(AacAv3.Av3Gesture.HandOpen))
                    .Or().When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_id[(Position.World, e, t)]));
                    
                    world.TransitionsTo(one_handed)
                    .When(layer.Av3().ItIsLocal()).And(staff_shaft_left_hand_contact.IsTrue()).And(layer.Av3().GestureLeft.IsEqualTo(AacAv3.Av3Gesture.Fist))
                    .Or().When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_id[(Position.OneHanded, e, t)]));
                    
                    world.TransitionsTo(store)
                    .When(layer.Av3().ItIsLocal()).And(menu_deploy.IsFalse())
                    .Or().When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_id[(Position.Storage, e, t)]));

                    // Trail if supported
                    if(steady_states.TryGetValue((Position.Trail, e, t), out AacFlState trail)) {
                        storage.TransitionsTo(trail)
                        .When(layer.Av3().ItIsLocal()).And(trail_contact.IsTrue()).And(layer.Av3().GestureRight.IsEqualTo(AacAv3.Av3Gesture.Fingerpoint))
                        .Or().When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_id[(Position.Trail, e, t)]));

                        trail.TransitionsTo(storage)
                        .When(layer.Av3().ItIsLocal()).And(layer.Av3().GestureRight.IsNotEqualTo(AacAv3.Av3Gesture.Fingerpoint))
                        .Or().When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_id[(Position.Storage, e, t)]));
                    }
                }
            }

            // Effect swap, from effect e to another.
            // Ignored : Storage due to no contacts ; TwoHanded as both hands are taken.
            foreach(Position p in new[]{ Position.OneHanded, Position.World }) {
                foreach(Effect e in System.Enum.GetValues(typeof(Effect))) {
                    foreach(Target t in System.Enum.GetValues(typeof(Target))) {
                        if(!steady_states.TryGetValue((p, e, t), out AacFlState steady_state)) continue;
                        TargetConfig t_config = target_config[t];

                        foreach(Effect d in System.Enum.GetValues(typeof(Effect))) {
                            // From e to d
                            if(d == e) continue; // Ignore self transition
                            
                            // Fallback to window if sphere mode is not available.
                            // This is also how we can come back from raycast mode ; just select a non-raycast effect, of which we have at least "None".
                            EffectConfig d_config = effect_config[d];
                            Target d_target = d_config.CanSphere ? t : Target.Window;
                            AacFlState d_state = steady_states[(p, d, d_target)];
                            int d_state_id = state_id[(p, d, d_target)];

                            // Add intermediate transition state for dissolve effects
                            if (e == Effect.None && d_config.HasDissolve)
                            {
                                // Radial un-dissolve from None to any.
                                Debug.Assert(t == Target.Window);
                                AacFlState deploy = layer.NewState($"{p}@{e}->{d}");
                                AacFlClip clip = aac.NewClip();
                                deploy.Drives(synced, d_state_id).DrivingLocally(); // Early sync
                                deploy.WithAnimation(clip);

                                clip.TogglingComponent(config.Surface, true);
                                clip.SwappingMaterial(config.Surface, 0, d_config.Material(config));
                                clip.Animating(SetVector4(config.Staff, "material._EmissionMask_Staff_ST", d_config.EmissionST));
                                clip.Animating(edit => {
                                    edit.Animates(config.Surface, "material._Overlay_Border_Dissolve_Config.x").WithSecondsUnit(keys => {
                                        keys.Linear(0f, t_config.DissolvedRadius);
                                        keys.Linear(0.5f, t_config.Dissolve.x);
                                    });
                                    edit.Animates(config.Surface, "material._Overlay_Border_Dissolve_Config.y").WithOneFrame(t_config.Dissolve.y);
                                    edit.Animates(config.Surface, "material._Overlay_Border_Dissolve_Config.z").WithOneFrame(t_config.Dissolve.z);
                                    edit.Animates(config.Surface, "material._Overlay_Border_Dissolve_Config.w").WithOneFrame(t_config.Dissolve.w);
                                });

                                deploy.AutomaticallyMovesTo(d_state);
                                d_state = deploy;
                            }
                            else if (effect_config[e].HasDissolve && ((!d_config.CanSphere && t != Target.Window) || d == Effect.None))
                            {
                                // Radial dissolve.
                                // Either because we move toward a window-only effect and are not window : dissolve then swap to window
                                // Or dissolve due to None, even if window
                                AacFlState dissolve = layer.NewState($"{p}@{e}->{d}@{t}");
                                AacFlClip clip = aac.NewClip();
                                dissolve.Drives(synced, d_state_id).DrivingLocally(); // Early sync
                                dissolve.WithAnimation(clip);

                                clip.Animating(SetVector4(config.Staff, "material._EmissionMask_Staff_ST", d_config.EmissionST));
                                clip.Animating(edit => {
                                    // No need to set yzw, they are already set from steady state
                                    edit.Animates(config.Surface, "material._Overlay_Border_Dissolve_Config.x").WithSecondsUnit(keys => {
                                        keys.Linear(0f, t_config.Dissolve.x);
                                        keys.Linear(0.5f, t_config.DissolvedRadius);
                                    });
                                    // Let steady state handle renderer swap or disable.
                                });

                                dissolve.AutomaticallyMovesTo(d_state);
                                d_state = dissolve;
                            }
                            // From window to window : no special case, instant swap
                            
                            steady_state.TransitionsTo(d_state)
                            .When(layer.Av3().ItIsLocal()).And(effect_contacts[d].IsTrue())
                            .Or().When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(d_state_id));
                        }
                    }
                }
            }

            // Target swap.
            // Ignore storage, and two handed as we need the right hand free.
            var positions_that_can_target_swap = new[]{ Position.OneHanded, Position.World };
            foreach(Effect e in System.Enum.GetValues(typeof(Effect))) {
                if(!effect_config[e].CanSphere) continue; // Ignore if we are restricted to window mode.

                foreach(Position p in positions_that_can_target_swap) {
                    AacFlState window = steady_states[(p, e, Target.Window)];
                    AacFlState hand = steady_states[(p, e, Target.Hand)];
                    AacFlState staff = steady_states[(p, e, Target.Staff)];
                    AacFlState raycast = steady_states[(p, e, Target.Raycast)];

                    window.TransitionsTo(hand).WithTransitionDurationSeconds(0.1f)
                    .When(layer.Av3().ItIsLocal()).And(main_ring_contact.IsTrue()).And(layer.Av3().GestureRight.IsEqualTo(AacAv3.Av3Gesture.Fist))
                    .Or().When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_id[(p, e, Target.Hand)]));

                    hand.TransitionsTo(window).WithTransitionDurationSeconds(0.1f)
                    .When(layer.Av3().ItIsLocal()).And(main_ring_contact.IsTrue()).And(layer.Av3().GestureRight.IsEqualTo(AacAv3.Av3Gesture.HandOpen))
                    .Or().When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_id[(p, e, Target.Window)]));

                    hand.TransitionsTo(staff).WithTransitionDurationSeconds(0.3f)
                    .When(layer.Av3().ItIsLocal()).And(aoe_ring_contact.IsTrue()).And(layer.Av3().GestureRight.IsEqualTo(AacAv3.Av3Gesture.HandOpen))
                    .Or().When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_id[(p, e, Target.Staff)]));

                    staff.TransitionsTo(hand).WithTransitionDurationSeconds(0.3f)
                    .When(layer.Av3().ItIsLocal()).And(aoe_ring_contact.IsTrue()).And(layer.Av3().GestureRight.IsEqualTo(AacAv3.Av3Gesture.Fist))
                    .Or().When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_id[(p, e, Target.Hand)]));

                    AacFlState raycasting = layer.NewState($"{p}@{e}@Raycasting");
                    raycasting.Drives(synced, state_id[(p, e, Target.Raycast)]).DrivingLocally(); // Early sync
                    {
                        AacFlClip clip = aac.NewClip();
                        raycasting.WithAnimation(clip);

                        // World drop raycast assembly and start raycast
                        clip.Animating(SetConstraintWorldFixed(raycaster_parent_constraint, true));
                        clip.TogglingComponent(config.Raycaster, true);
                        clip.Animating(edit => {
                            edit.AnimatesColor(config.Staff, "material._EmissionColor_Staff").WithOneFrame(emissive_red);
                            // Move raycast distance and anchor in sync, until a hit.
                            // Anchor is not directly raycasted, as during the animation an object closer than current distance could be hit, teleporting the anchor (bad).
                            edit.Animates(config.Raycaster, "distance").WithSecondsUnit(keys => keys.Linear(0f, 0.1f).Linear(3f, 100f));
                            edit.Animates(config.RaycastAnchor, "m_LocalPosition.z").WithSecondsUnit(keys => keys.Linear(0f, 0.1f).Linear(3f, 100f));
                            // Short transition from hand to raycast anchor
                            edit.Animates(surface_parent_constraint, $"Sources.source{(int) Target.Hand}.Weight").WithSecondsUnit(keys => keys.Linear(0f, 1f).Linear(0.1f, 0f));
                            edit.Animates(surface_parent_constraint, $"Sources.source{(int) Target.Raycast}.Weight").WithSecondsUnit(keys => keys.Linear(0f, 0f).Linear(0.1f, 1f));
                        });
                    }

                    AacFlState raycast_deploy = layer.NewState($"{p}@{e}@Deploy");
                    raycast_deploy.Drives(raycast_hit, false); // Ensure reset
                    raycast_deploy.WithAnimation(aac.NewClip().Animating(clip => {
                        clip.Animates(config.Raycaster, "m_Enabled").WithOneFrame(0); // Not needed anymore
                        
                        TargetConfig hand = target_config[Target.Hand];
                        TargetConfig raycast = target_config[Target.Raycast];
                        clip.Animates(config.Surface.transform, "m_LocalScale.x").WithSecondsUnit(keys => keys.Linear(0f, hand.SurfaceScale.x).Linear(0.3f, raycast.SurfaceScale.x));
                        clip.Animates(config.Surface.transform, "m_LocalScale.y").WithSecondsUnit(keys => keys.Linear(0f, hand.SurfaceScale.y).Linear(0.3f, raycast.SurfaceScale.y));
                        clip.Animates(config.Surface.transform, "m_LocalScale.z").WithSecondsUnit(keys => keys.Linear(0f, hand.SurfaceScale.z).Linear(0.3f, raycast.SurfaceScale.z));
                        if(effect_config[e].HasDissolve) {
                            // Only z is changed between hand to raycast
                            clip.Animates(config.Surface, "material._Overlay_Border_Dissolve_Config.z").WithSecondsUnit(keys => keys.Linear(0f, hand.Dissolve.z).Linear(0.3f, raycast.Dissolve.z));
                        }
                    }));

                    hand.TransitionsTo(raycasting)
                    .When(layer.Av3().ItIsLocal()).And(layer.Av3().GestureRight.IsEqualTo(AacAv3.Av3Gesture.Fingerpoint))
                    .Or().When(layer.Av3().ItIsRemote()).And(synced.IsEqualTo(state_id[(p, e, Target.Raycast)]));

                    raycasting.TransitionsTo(raycast_deploy).When(raycast_hit.IsTrue());
                    raycasting.AutomaticallyMovesTo(raycast_deploy); // Fallback
                    raycast_deploy.AutomaticallyMovesTo(raycast);
                    // No return from raycast here. Use None effect button.
                }
            }

            // Fallback synced transitions : all previous transitions were local (follow 1 step from master).
            // In case of desync, just resets the remote through init.
            // Always define last to let the nice transitions take priority.
            foreach(Effect e in System.Enum.GetValues(typeof(Effect))) {
                foreach(Position p in System.Enum.GetValues(typeof(Position))) {
                    foreach(Target t in System.Enum.GetValues(typeof(Target))) {
                        if(steady_states.TryGetValue((p, e, t), out AacFlState steady_state)) {
                            steady_state.TransitionsTo(init_state).When(layer.Av3().ItIsRemote()).And(synced.IsNotEqualTo(state_id[(p, e, t)]));
                        }
                    }
                }
            }

            ma.NewMergeAnimator(animator_controller.AnimatorController, VRCAvatarDescriptor.AnimLayerType.FX);

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

        static private System.Action<AacFlEditClip> SetVector4(Component component, string property, Vector4 v) {
            return clip => {
                clip.Animates(component, $"{property}.x").WithOneFrame(v.x);
                clip.Animates(component, $"{property}.y").WithOneFrame(v.y);
                clip.Animates(component, $"{property}.z").WithOneFrame(v.z);
                clip.Animates(component, $"{property}.w").WithOneFrame(v.w);
            };
        }
    }
}
#endif