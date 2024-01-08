#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.Linq;
using AnimatorAsCode.V0;
using UnityEditor;
using UnityEditor.Animations;
using UnityEngine;
using UnityEngine.Animations;
using VRC.Dynamics;
using VRC.SDK3.Avatars.Components;
using VRC.SDK3.Dynamics.Contact.Components;

namespace Lereldarion {
    public class ReplicatorAvatarAnimator : MonoBehaviour {
        [Header("Aac")]
        public VRCAvatarDescriptor avatar;
        public AnimatorController assetContainer;
        public string assetKey;

        [Header("Mesh")]
        public SkinnedMeshRenderer main_mesh;

        [Header("Tools")]
        public Transform sword_bone;
        public Transform shield_bone;
        public ContactReceiver left_lower_arm_contact;
        public ContactReceiver right_lower_arm_contact;
        public Transform pet_system_container;
        public Transform remote_anchor;

        [Header("Visor")]
        public Transform visor_bone;
        public Transform stable_sized_head;
        public Material[] overlays;

        [Header("Material swaps")]
        public Material[] body;
    }

    [CustomEditor(typeof(ReplicatorAvatarAnimator), true)]
    public class ReplicatorAvatarAnimator_Editor : Editor {
        private void Create() {
            var editor = (ReplicatorAvatarAnimator) target;
            var aac = AnimatorAsCode(editor);

            var dbt = new DirectBlendTree(aac);
            CreateAnimatorSword(editor, aac, aac.CreateSupportingFxLayer("Sword"));
            CreateAnimatorShield(editor, aac, aac.CreateSupportingFxLayer("Shield"));
            CreateAnimatorDislocation(editor, aac, aac.CreateSupportingFxLayer("Dislocation"), dbt);
            CreateAnimatorFace(editor, dbt);
            CreateAnimatorMaterialSwaps(editor, dbt);
            CreateAnimatorVisor(editor, aac, aac.CreateSupportingFxLayer("Visor"));
            CreateAnimatorPetSystems(editor, aac, dbt);
            CreateAnimatorAudioLink(editor, dbt);
            CreateAnimatorAnchor(editor, dbt);
        }

        private void Remove() {
            var editor = (ReplicatorAvatarAnimator) target;
            var aac = AnimatorAsCode(editor);
            aac.RemoveAllSupportingLayers("DBT");
            aac.RemoveAllSupportingLayers("Sword");
            aac.RemoveAllSupportingLayers("Shield");
            aac.RemoveAllSupportingLayers("Dislocation");
            aac.RemoveAllSupportingLayers("Visor");
            RemoveAnimatorsPetSystems(editor, aac);
        }

        private const float frame_delay = 1f/60f;

        // It seems that when animating material properties, all material properties can be reached through "material".
        // Probably due to MaterialPropertyBlock on the rendered.
        private const string block_material = "material"; // slot 0
        private const string detail_material = "material"; // slot 1
        private const int overlay_material_slot = 2;
        private const string shield_material = "material"; // slot 3

        //////////////////////////////////////////////////////////////////////////////////////////////////////////////////

        private void CreateAnimatorSword(ReplicatorAvatarAnimator editor, AacFlBase aac, AacFlLayer layer) {
            // Sword ; same layer for both local detection and synced action
            // To avoid conflict between blend of parent and aim constraint, the aim constraint moves an anchor bone (always on),
            // and the parent constraint blends between storage and this aimed bone
            var sword_storage_contact = layer.BoolParameter("Sword/StorageContact");
            var synced = layer.BoolParameter("Sword/Synced");
            var drives_shield = layer.BoolParameter("Sword/DrivesShield"); // Grab action will move shield as well
            var shield_synced = layer.BoolParameter("Shield/Synced");

            // dislocation : disable shield
            var arm_cut = layer.FloatParameter("Dislocation/RightArm/Cut");
            var arm_cut_synced = layer.FloatParameter("Dislocation/RightArm/Synced");
            float arm_cut_hand_value = 0.8f;
            var dislocation_global = layer.BoolParameter("Dislocation/Global/Synced");

            var sword_contact_sender = editor.sword_bone.GetComponent<VRCContactSender>();
            var constraint = editor.sword_bone.GetComponent<ParentConstraint>();
            string blendshape = "Deploy_Sword";
            
            float dt = 0.7f;

            var retracted = layer.NewState("Retracted", 0, 1).WithAnimation(aac.NewClip("sword_retracted").Animating(clip => {
                AnimateConstraintSources(clip, constraint, (curve, i) => curve.WithOneFrame(i == 0));
                clip.Animates(editor.main_mesh, $"blendShape.{blendshape}").WithOneFrame(0);
                clip.Animates(sword_contact_sender, "m_Enabled").WithOneFrame(0);
                clip.Animates(editor.right_lower_arm_contact, "m_Enabled").WithOneFrame(1);
            }));
            
            var deployed = layer.NewState("Deployed", 2, 1).WithAnimation(aac.NewClip("sword_deployed").Animating(clip => {
                AnimateConstraintSources(clip, constraint, (curve, i) => curve.WithOneFrame(i == 1));
                clip.Animates(editor.main_mesh, $"blendShape.{blendshape}").WithOneFrame(100);
                clip.Animates(sword_contact_sender, "m_Enabled").WithOneFrame(1);
                clip.Animates(editor.right_lower_arm_contact, "m_Enabled").WithOneFrame(0); // "Protect" (disable) contact when sword deployed
            }));

            var deploying = layer.NewState("Deploying", 1, 2)
                .Drives(synced, true).DrivingLocally()
                .WithAnimation(aac.NewClip("sword_deploying").Animating(clip => {
                    AnimateConstraintSources(clip, constraint, (curve, i) => curve.WithSecondsUnit(keys => keys.Easing(0f, i == 0).Easing(dt, i == 1)));
                    clip.Animates(editor.main_mesh, $"blendShape.{blendshape}").WithSecondsUnit(keys => keys.Easing(0f, 0f).Easing(dt, 100f));
                }));
            var deploying_drives_shield = layer.NewState("Deploying Shield", 0, 2).Drives(shield_synced, true).DrivingLocally();
            retracted.TransitionsTo(deploying_drives_shield)
                .When(sword_storage_contact.IsTrue()).And(layer.Av3().GestureRight.IsEqualTo(AacAv3.Av3Gesture.Fist)).And(drives_shield.IsTrue())
                    .And(arm_cut_synced.IsGreaterThan(arm_cut_hand_value)).And(dislocation_global.IsFalse());
            retracted.TransitionsTo(deploying)
                .When(sword_storage_contact.IsTrue()).And(layer.Av3().GestureRight.IsEqualTo(AacAv3.Av3Gesture.Fist)).And(drives_shield.IsFalse())
                    .And(arm_cut_synced.IsGreaterThan(arm_cut_hand_value)).And(dislocation_global.IsFalse())
                .Or().When(synced.IsTrue())
                    .And(arm_cut_synced.IsGreaterThan(arm_cut_hand_value)).And(dislocation_global.IsFalse());
            deploying_drives_shield.AutomaticallyMovesTo(deploying);
            deploying.AutomaticallyMovesTo(deployed);

            var retracting = layer.NewState("Retracting", 1, 0)
                .Drives(synced, false).DrivingLocally()
                .WithAnimation(aac.NewClip("sword_retracting").Animating(clip => {
                    AnimateConstraintSources(clip, constraint, (curve, i) => curve.WithSecondsUnit(keys => keys.Linear(0f, i == 1).Easing(dt, i == 0)));
                    clip.Animates(editor.main_mesh, $"blendShape.{blendshape}").WithSecondsUnit(keys => keys.Linear(0f, 100f).Easing(dt, 0f));
                    clip.Animates(sword_contact_sender, "m_Enabled").WithOneFrame(0); // Early disable to prevent triggering animations during retract
                }));
            var retracting_drives_shield = layer.NewState("Retracting Shield", 2, 0).Drives(shield_synced, false).DrivingLocally();
            deployed.TransitionsTo(retracting_drives_shield)
                .When(sword_storage_contact.IsTrue()).And(layer.Av3().GestureRight.IsEqualTo(AacAv3.Av3Gesture.HandOpen)).And(drives_shield.IsTrue());
            deployed.TransitionsTo(retracting)
                .When(sword_storage_contact.IsTrue()).And(layer.Av3().GestureRight.IsEqualTo(AacAv3.Av3Gesture.HandOpen)).And(drives_shield.IsFalse())
                .Or().When(synced.IsFalse())
                .Or().When(arm_cut.IsLessThan(arm_cut_hand_value))
                .Or().When(arm_cut_synced.IsLessThan(arm_cut_hand_value))
                .Or().When(dislocation_global.IsTrue());
            retracting_drives_shield.AutomaticallyMovesTo(retracting);
            retracting.AutomaticallyMovesTo(retracted);
        }

        private void CreateAnimatorShield(ReplicatorAvatarAnimator editor, AacFlBase aac, AacFlLayer layer) {
            // Shield : blendshape and constraint swap
            var synced = layer.BoolParameter("Shield/Synced");

            // dislocation : disable shield
            var arm_cut = layer.FloatParameter("Dislocation/LeftArm/Cut");
            var arm_cut_synced = layer.FloatParameter("Dislocation/LeftArm/Synced");
            float arm_cut_hand_value = 0.8f;
            var dislocation_global = layer.BoolParameter("Dislocation/Global/Synced");

            var constraint = editor.shield_bone.GetComponent<RotationConstraint>();
            string blendshape = "Deploy_Shield";
            var collider = editor.shield_bone.GetComponent<BoxCollider>();
            
            // transitions times
            float block_dt = 0.7f;
            float shield_dt = 0.2f;

            var retracted = layer.NewState("Retracted")
                .WithAnimation(aac.NewClip("shield_retracted").Animating(clip => {
                    AnimateConstraintSources(clip, constraint, (curve, i) => curve.WithOneFrame(i == 0));
                    clip.Animates(editor.main_mesh, $"blendShape.{blendshape}").WithOneFrame(0);
                    clip.Animates(editor.main_mesh, $"{shield_material}._Falloff_Radius").WithOneFrame(0);
                    clip.Animates(editor.left_lower_arm_contact, "m_Enabled").WithOneFrame(1); 
                    clip.Animates(collider, "m_Enabled").WithOneFrame(0);
                }));
            
            var deployed = layer.NewState("Deployed").Shift(retracted, 2, 0)
                .WithAnimation(aac.NewClip("shield_deployed").Animating(clip => {
                    AnimateConstraintSources(clip, constraint, (curve, i) => curve.WithOneFrame(i == 1));
                    clip.Animates(editor.main_mesh, $"blendShape.{blendshape}").WithOneFrame(100);
                    clip.Animates(editor.main_mesh, $"{shield_material}._Falloff_Radius").WithOneFrame(0.5f);
                    clip.Animates(editor.left_lower_arm_contact, "m_Enabled").WithOneFrame(0); // "Protect" (disable) contact when shield deployed
                    clip.Animates(collider, "m_Enabled").WithOneFrame(1);
                }));

            var deploying = layer.NewState("Deploying").Shift(retracted, 1, 1)
                .Drives(synced, true).DrivingLocally()
                .WithAnimation(aac.NewClip("shield_deploying").Animating(clip => {
                    AnimateConstraintSources(clip, constraint, (curve, i) => curve.WithSecondsUnit(keys => keys.Easing(0f, i == 0).Easing(block_dt, i == 1)));
                    clip.Animates(editor.main_mesh, $"blendShape.{blendshape}").WithSecondsUnit(keys => keys.Easing(0f, 0f).Easing(block_dt, 100f));
                    clip.Animates(editor.main_mesh, $"{shield_material}._Falloff_Radius").WithSecondsUnit(keys => keys.Linear(0f, 0f).Easing(block_dt, 0f).Easing(block_dt + shield_dt, 0.5f));
                }));
            retracted.TransitionsTo(deploying).When(synced.IsTrue())
                .And(arm_cut_synced.IsGreaterThan(arm_cut_hand_value)).And(dislocation_global.IsFalse());
            deploying.AutomaticallyMovesTo(deployed);

            var retracting = layer.NewState("Retracting").Shift(retracted, 1, -1)
                .Drives(synced, false).DrivingLocally()
                .WithAnimation(aac.NewClip("shield_retracting").Animating(clip => {
                    AnimateConstraintSources(clip, constraint, (curve, i) => curve.WithSecondsUnit(keys => keys.Linear(0f, i == 1).Easing(shield_dt, i == 1).Easing(shield_dt + block_dt, i == 0)));
                    clip.Animates(editor.main_mesh, $"blendShape.{blendshape}").WithSecondsUnit(keys => keys.Linear(0f, 100f).Easing(shield_dt, 100f).Easing(shield_dt + block_dt, 0f));
                    clip.Animates(editor.main_mesh, $"{shield_material}._Falloff_Radius").WithSecondsUnit(keys => keys.Easing(0f, 0.5f).Easing(shield_dt, 0f));
                    clip.Animates(collider, "m_Enabled").WithOneFrame(0);
                }));
            deployed.TransitionsTo(retracting)
                .When(synced.IsFalse())
                .Or().When(arm_cut.IsLessThan(arm_cut_hand_value))
                .Or().When(arm_cut_synced.IsLessThan(arm_cut_hand_value))
                .Or().When(dislocation_global.IsTrue());
            retracting.AutomaticallyMovesTo(retracted);
        }

        //////////////////////////////////////////////////////////////////////////////////////////////////////////////////

        private void CreateAnimatorDislocation(ReplicatorAvatarAnimator editor, AacFlBase aac,  AacFlLayer layer, DirectBlendTree dbt) {
            // When an animation is trigerred, run for some time without checking contacts. This creates an "immunity window".
            // Animation timing is designed so that animation will complete during this time (all broken blocks through the floor).
            var immunity_secs = 3f;

            // General design of layer : store state as cached and synced parameters.
            // State logic always return to standby after animation is done. State machine implies only one animation will run at once.
            // Transition are evaluated by order of definition, so place higher priority ones first
            var standby = layer.NewState("Standby");

            // Limbs TODO add legs
            foreach (var name_and_x_sign in new Dictionary<string, int>{{"LeftArm", -1}, {"RightArm", 1}})
            {
                var name = name_and_x_sign.Key;
                var x_sign = name_and_x_sign.Value;

                // Define a 1D coordinate along the arm ; stored in uv2 to be independent of skinning
                // Use combination of proximity contact (on elbow center) + pair of capsule trigger contacts. Normalize to [-1, 1] for use with synced floats.

                var upper_contact = layer.BoolParameter($"Dislocation/{name}/Upper");
                var lower_contact = layer.BoolParameter($"Dislocation/{name}/Lower");
                var proximity_contact = layer.FloatParameter($"Dislocation/{name}/Proximity"); // 1 at center, 0 on edge

                var current_cut_offset = layer.FloatParameter($"Dislocation/{name}/Cut");
                var synced_cut_offset = layer.FloatParameter($"Dislocation/{name}/Synced");

                var cut_animation = layer.NewState($"{name} Animation").Shift(standby, 3 * x_sign, 0);

                var upper_cut_remap = layer.NewState($"{name}/Upper").Over(cut_animation)
                    .DrivingRemaps(proximity_contact, 0f, 1f, current_cut_offset, -1f, 0f); // Flip to [-1,0]
                standby.TransitionsTo(upper_cut_remap).When(upper_contact.IsTrue());
                
                var lower_cut_remap = layer.NewState($"{name}/Lower").Under(cut_animation)
                    .DrivingRemaps(proximity_contact, 1f, 0f, current_cut_offset, 0f, 1f);
                standby.TransitionsTo(lower_cut_remap).When(lower_contact.IsTrue()).And(upper_contact.IsFalse()).And(synced_cut_offset.IsGreaterThan(0f));

                // Implement unsupported `Cut < Synced` with OR of `A < c && c < B` for multiple thresholds. Order matters.
                for (float c = 0.9f; c > -0.6f; c += -0.1f) {
                    upper_cut_remap.TransitionsTo(cut_animation).When(current_cut_offset.IsLessThan(c)).And(synced_cut_offset.IsGreaterThan(c));
                    lower_cut_remap.TransitionsTo(cut_animation).When(current_cut_offset.IsLessThan(c)).And(synced_cut_offset.IsGreaterThan(c));
                }
                // If no threshold worked, reset
                upper_cut_remap.AutomaticallyMovesTo(standby);
                lower_cut_remap.AutomaticallyMovesTo(standby);

                cut_animation.WithAnimation(
                    DirectBlendTree.Create1D(aac, current_cut_offset, new[] {-1f, 1f}, (clip, cut_offset) => {
                        clip.Animating(edit_clip => {
                            // Set animation cutoff from current cut with blendtree.
                            edit_clip.Animates(editor.main_mesh, $"{block_material}._Replicator_Dislocation_{name}.y").WithOneFrame(cut_offset);
                            // Replicate the time animation in both sides of the blendtree
                            edit_clip.Animates(editor.main_mesh, $"{block_material}._Replicator_Dislocation_{name}.z").WithSecondsUnit(keys => keys.Linear(0f, 0f).Linear(immunity_secs, immunity_secs)); // Time
                        });
                        clip.NonLooping(); // Ensure we get out. Is it necessary ?
                    })
                );

                var cut_animation_end = layer.NewState($"{name} Animation Finish").Shift(cut_animation, -1 * x_sign, 0)
                    .DrivingCopies(current_cut_offset, synced_cut_offset).DrivingLocally()
                    .WithAnimation(
                        aac.NewClip().Animating(clip => {
                            // Reset time with some delay to let synced show cutoff update.
                            clip.Animates(editor.main_mesh, $"{block_material}._Replicator_Dislocation_{name}.z").WithSecondsUnit(keys => keys.Constant(1f, 0f).Constant(1f + frame_delay, 0f));
                        })
                    );
                cut_animation.AutomaticallyMovesTo(cut_animation_end);
                cut_animation_end.AutomaticallyMovesTo(standby);

                standby.Drives(current_cut_offset, 1f); // Resets so that hand object logic can use it for immediate detection. Drives NOT locally.

                // Track synced show_cutoff value to follow radial puppet.
                dbt.Add1D(synced_cut_offset, new[] {-1f, 1f}, (clip, cut_offset) => {
                    clip.Animating(edit => edit.Animates(editor.main_mesh, $"{block_material}._Replicator_Dislocation_{name}.x").WithOneFrame(cut_offset));
                });
            }

            // Global
            {
                var contact = layer.BoolParameter("Dislocation/Global/Contact");

                var synced_state = layer.BoolParameter("Dislocation/Global/Synced"); // True = dislocated

                var reassembly_secs = immunity_secs + 2f; // spatial delay requires a bit more time to complete 

                // Ensure reset if animation has been occluded
                standby.WithAnimation(aac.NewClip("global_standby").Animating(clip => {
                    clip.Animates(editor.main_mesh, $"{block_material}._Replicator_Dislocation_Global.x").WithOneFrame(1); // Show
                    clip.Animates(editor.main_mesh, $"{block_material}._Replicator_Dislocation_Global.y").WithOneFrame(0); // Time
                    clip.Animates(editor.main_mesh, $"{block_material}._Replicator_Dislocation_Global.z").WithOneFrame(0); // Delay factor
                }));

                // Stay in dislocated state, as we do not need to look for arms when completely dislocated
                var dislocated = layer.NewState("Global/Dislocated").Shift(standby, 0, 4)
                    .WithAnimation(aac.NewClip("global_dislocated").Animating(clip => {
                        clip.Animates(editor.main_mesh, $"{block_material}._Replicator_Dislocation_Global.x").WithOneFrame(0); // Show
                        clip.Animates(editor.main_mesh, $"{block_material}._Replicator_Dislocation_Global.y").WithOneFrame(reassembly_secs); // Time
                        clip.Animates(editor.main_mesh, $"{block_material}._Replicator_Dislocation_Global.z").WithOneFrame(0); // Delay factor
                        clip.Animates(editor.main_mesh, $"{detail_material}._DislocationGlobal").WithOneFrame(1);
                    }));

                // This animation should run in parallel on local & remote avatars, with some lag. Or be trigerred by sync
                var dislocating = layer.NewState("Global/Dislocating").RightOf(dislocated)
                    .Drives(synced_state, true).DrivingLocally()
                    .WithAnimation(aac.NewClip("global_dislocating").Animating(clip => {
                        clip.Animates(editor.main_mesh, $"{block_material}._Replicator_Dislocation_Global.x").WithSecondsUnit(keys => keys.Constant(0f, 1f).Constant(immunity_secs, 0f)); // Show
                        clip.Animates(editor.main_mesh, $"{block_material}._Replicator_Dislocation_Global.y").WithSecondsUnit(keys => keys.Linear(0f, 0f).Linear(immunity_secs, immunity_secs)); // Time
                        clip.Animates(editor.main_mesh, $"{block_material}._Replicator_Dislocation_Global.z").WithOneFrame(0.2f); // Spatial delay factor, "chain explosion effect"
                        clip.Animates(editor.main_mesh, $"{detail_material}._DislocationGlobal").WithOneFrame(1); // Immediate hiding of details
                    }));
                standby.TransitionsTo(dislocating).When(contact.IsTrue()).Or().When(synced_state.IsTrue());
                dislocating.AutomaticallyMovesTo(dislocated);

                // Reconstruction driven by synced state being manually reset (menu)
                var reassembly = layer.NewState("Global/Reassembly").LeftOf(dislocated)
                    .WithAnimation(aac.NewClip("global_reassembly").Animating(clip => {
                        clip.Animates(editor.main_mesh, $"{block_material}._Replicator_Dislocation_Global.x").WithOneFrame(1); // Show
                        clip.Animates(editor.main_mesh, $"{block_material}._Replicator_Dislocation_Global.y").WithSecondsUnit(keys => keys.Linear(0f, reassembly_secs).Linear(reassembly_secs, 0f).Constant(reassembly_secs + frame_delay, 0f)); // Time
                        clip.Animates(editor.main_mesh, $"{block_material}._Replicator_Dislocation_Global.z").WithOneFrame(1); // Spatial delay factor "slow reassembly"
                        clip.Animates(editor.main_mesh, $"{detail_material}._DislocationGlobal").WithSecondsUnit(keys => keys.Constant(0, 1).Constant(reassembly_secs, 0).Constant(reassembly_secs + frame_delay, 0)); // Restore at the end
                    }));
                dislocated.TransitionsTo(reassembly).When(synced_state.IsFalse());
                reassembly.AutomaticallyMovesTo(standby);
            }
        }

        //////////////////////////////////////////////////////////////////////////////////////////////////////////////////

        private void CreateAnimatorFace(ReplicatorAvatarAnimator editor, DirectBlendTree dbt) {
            // Eyes are blendshapes changing the eye expression, driven from int : 0 = none, 1 = smiling, etc
            var face_blendshapes = new[] {
                "Eye_Smiling",
                "Eye_Closed",
                "Eye_Star",
            };
            dbt.Add1D(
                dbt.Layer.FloatParameter("Face"),
                Enumerable.Range(0, face_blendshapes.Length + 1).Select(i => (float) i).ToArray(),
                (clip, active_index) => {
                    foreach (var (blendshape_name, index) in face_blendshapes.Select((bn, i) => (bn, i + 1))) {
                        // Blendshape are between 0-100
                        clip.BlendShape(editor.main_mesh, blendshape_name, (int) active_index == index ? 100f : 0f);
                    }
                }
            );

            // Animate mouth emission from voice builtin parameter.
            dbt.Add1D(dbt.Layer.Av3().Voice, new[] {0f, 1f}, (clip, voice) => {
                clip.Animating(edit => edit.Animates(editor.main_mesh, $"{shield_material}._MouthEmissionMultiplier").WithOneFrame(voice));
            });
        }

        private void CreateAnimatorMaterialSwaps(ReplicatorAvatarAnimator editor, DirectBlendTree dbt) {
            int n = editor.body.Length;
            Debug.Assert(n >= 2);
            float factor_01 = editor.body.Length - 1;

            dbt.Add1D(
                dbt.Layer.FloatParameter("Material"),
                Enumerable.Range(0, n).Select(i => i / factor_01).ToArray(),
                (clip, material_id_01) => {
                    clip.SwappingMaterial(editor.main_mesh, 0, editor.body[(int) Math.Round(material_id_01 * factor_01)]);
                }
            );
        }

        private void CreateAnimatorAudioLink(ReplicatorAvatarAnimator editor, DirectBlendTree dbt) {
            dbt.Add1D(dbt.Layer.FloatParameter("AudioLink"), new[] {0f, 1f}, (clip, enable) => {
                clip.Animating(edit => {
                    edit.Animates(editor.main_mesh, $"{block_material}._Replicator_AudioLink").WithOneFrame(enable);
                    foreach(MeshRenderer pet_renderer in editor.pet_system_container.GetComponentsInChildren<MeshRenderer>(true)) {
                        edit.Animates(pet_renderer, "material._Replicator_AudioLink").WithOneFrame(enable);
                    }
                });
            });
        }

        //////////////////////////////////////////////////////////////////////////////////////////////////////////////////

        private enum VisorPosition { Chest, Hand, Head } // order must match constraint source order

        private void CreateAnimatorVisor(ReplicatorAvatarAnimator editor, AacFlBase aac, AacFlLayer layer) {
            // Deployable window with an overlay surface.
            // Can be transitioned between various attachment points (chest, head) using the hand as temporary location. Grab as trigger.
            // Multiple overlays ; slide finger on the bottom border to select them
            var constraint = editor.visor_bone.GetComponent<ParentConstraint>();
            var overlay_controls = editor.visor_bone.Find("Controls").gameObject;

            var visor_support_bottom = editor.stable_sized_head.Find("Visor_Support_Bottom");
            var visor_support_top = editor.stable_sized_head.Find("Visor_Support_Top");
            var fake_head_scale = editor.stable_sized_head.GetComponent<ScaleConstraint>(); // Vrchat resizes the local head bone, revert this when visor is deployed TODO

            var chest_contact = layer.BoolParameter("Visor/ChestContact");
            var head_contact = layer.BoolParameter("Visor/HeadContact");

            var slider_contact = layer.BoolParameter("Visor/SliderContact");
            var slider_position = layer.FloatParameter("Visor/SliderPosition");

            var synced = layer.IntParameter("Visor/Synced");
            int linearize(int overlay_id, VisorPosition position) {
                return editor.overlays.Length * (int) position + overlay_id;
            }

            // Dislocation handling
            var left_arm_cut = layer.FloatParameter("Dislocation/LeftArm/Cut");
            var left_arm_cut_synced = layer.FloatParameter("Dislocation/LeftArm/Synced");
            float left_arm_cut_hand_value = 0.8f;
            var global_dislocation = layer.BoolParameter("Dislocation/Global/Synced");

            string blendshape = "Deploy_Visor";
            Vector3 support_top_rot(VisorPosition position) {
                return position == VisorPosition.Head ? new Vector3(62.382f, 0, 0) : new Vector3(-82, 0, 0);
            }
            Vector3 support_bottom_rot(VisorPosition position) {
                return position == VisorPosition.Head ? new Vector3(91.927f, 0, 0) : new Vector3(102.553f, 0, 0);
            }
            Vector3 support_bottom_pos(VisorPosition position) {
                return position == VisorPosition.Head ? new Vector3(0, 0.0446136f, 0.01424388f) : new Vector3(0, 0.0681f, -0.0531f);
            }

            var states = new Dictionary<(int, VisorPosition), AacFlState>();
            AacFlState make_steady_state(int overlay_id, VisorPosition position) {
                var state = layer.NewState($"{overlay_id}@{position}", overlay_id, (int) position);
                state.Drives(synced, linearize(overlay_id, position)).DrivingLocally();
                states.Add((overlay_id, position), state);
                // Animations are sufficiently similar to do here
                state.WithAnimation(aac.NewClip($"{overlay_id}@{position}")
                    .SwappingMaterial(editor.main_mesh, overlay_material_slot, editor.overlays[overlay_id])
                    .Toggling(overlay_controls, position != VisorPosition.Chest)
                    .BlendShape(editor.main_mesh, blendshape, position == VisorPosition.Chest ? 0f : 100f)
                    .Animating(clip => {
                        AnimateConstraintSources(clip, constraint, (curve, i) => curve.WithOneFrame(i == (int) position));
                        int fake_head_scale_enabled_source = position == VisorPosition.Head ? 1 : 0;
                        AnimateConstraintSources(clip, fake_head_scale, (curve, i) => curve.WithOneFrame(i == fake_head_scale_enabled_source)); // 0 is head scale, 1 hips scale
                        AnimateTransformVec3(clip, visor_support_top, "m_LocalEulerAngles", (curve, i) => curve.WithOneFrame(support_top_rot(position)[i]));
                        AnimateTransformVec3(clip, visor_support_bottom, "m_LocalEulerAngles", (curve, i) => curve.WithOneFrame(support_bottom_rot(position)[i]));
                        AnimateTransformVec3(clip, visor_support_bottom, "m_LocalPosition", (curve, i) => curve.WithOneFrame(support_bottom_pos(position)[i]));
                    })
                );
                return state;
            }

            // Common transition time for many changes
            const float dt = 0.3f;

            // States definitions and position transitions.
            // Hand cut forces moving away from hand, and prevents return to hand until fixed.
            for(int overlay_id = 0; overlay_id < editor.overlays.Length; overlay_id += 1) {
                var chest = make_steady_state(overlay_id, VisorPosition.Chest);
                var hand = make_steady_state(overlay_id, VisorPosition.Hand);
                var head = make_steady_state(overlay_id, VisorPosition.Head);


                chest.TransitionsTo(hand)
                    .WithTransitionDurationSeconds(dt)
                    .When(chest_contact.IsTrue()).And(layer.Av3().GestureLeft.IsEqualTo(AacAv3.Av3Gesture.Fist)).And(left_arm_cut_synced.IsGreaterThan(left_arm_cut_hand_value));

                hand.TransitionsTo(chest)
                    .WithTransitionDurationSeconds(dt)
                    .When(chest_contact.IsTrue()).And(layer.Av3().GestureLeft.IsEqualTo(AacAv3.Av3Gesture.HandOpen))
                    .Or().When(left_arm_cut.IsLessThan(left_arm_cut_hand_value)) // Immediate reaction to cut
                    .Or().When(left_arm_cut_synced.IsLessThan(left_arm_cut_hand_value)); // Long term ; synced value not updated during the animation but after.

                hand.TransitionsTo(head)
                    .WithTransitionDurationSeconds(dt)
                    .When(head_contact.IsTrue()).And(layer.Av3().GestureLeft.IsEqualTo(AacAv3.Av3Gesture.HandOpen));

                head.TransitionsTo(hand)
                    .WithTransitionDurationSeconds(dt)
                    .When(head_contact.IsTrue()).And(layer.Av3().GestureLeft.IsEqualTo(AacAv3.Av3Gesture.Fist)).And(left_arm_cut_synced.IsGreaterThan(left_arm_cut_hand_value));
            }
            // When slider contact is active, switch between overlays depending on the position of the finger
            for(int overlay_switch = 0; overlay_switch < editor.overlays.Length - 1; overlay_switch += 1) {
                foreach(VisorPosition position in Enum.GetValues(typeof(VisorPosition))) {
                    if (position == VisorPosition.Chest) { continue; } // contacts inactive anyway
                    float switch_position = (overlay_switch + 1) / (float) editor.overlays.Length;
                    int overlay_under = overlay_switch;
                    int overlay_above = overlay_switch + 1;
                    states[(overlay_under, position)].TransitionsTo(states[(overlay_above, position)])
                        .When(slider_contact.IsTrue()).And(slider_position.IsGreaterThan(switch_position));
                    states[(overlay_above, position)].TransitionsTo(states[(overlay_under, position)])
                        .When(slider_contact.IsTrue()).And(slider_position.IsLessThan(switch_position));
                }
            }
            // Synced transitions. Use the transition time blending.
            for(int overlay_id = 0; overlay_id < editor.overlays.Length; overlay_id += 1) {
                foreach(VisorPosition position in Enum.GetValues(typeof(VisorPosition))) {
                    layer.AnyTransitionsTo(states[(overlay_id, position)])
                        .WithNoTransitionToSelf()
                        .WithTransitionDurationSeconds(dt)
                        .When(synced.IsEqualTo(linearize(overlay_id, position)));
                }
            }
            // Hide overlay during global dislocation ; prevents floating overlay.
            // Instant, and synced, so no need to add guards to other transitions.
            // Blocs will be hidden by the dislocation animation on block shader. Only special support is using an override position in uv data.
            layer.AnyTransitionsTo(states[(0, VisorPosition.Chest)]).WithNoTransitionToSelf().When(global_dislocation.IsTrue());
        }

        //////////////////////////////////////////////////////////////////////////////////////////////////////////////////

        // Each pet is a parallel duplicated structure of one "rail" transform, with downward grounder (raycast), a pet at the end.
        // Spawning a pet = release rail from head to world, animate rail forward and display grounder tree.
        // One layer for each pet to have parallel animations...
        private void CreateAnimatorPetSystems(ReplicatorAvatarAnimator editor, AacFlBase aac, DirectBlendTree dbt) {
            var slot_active_flag_names = new List<string>();
            foreach(Transform child in editor.pet_system_container) {
                if (child.name.StartsWith("PetSystem")) {
                    CreateAnimatorPetSystem(aac, aac.CreateSupportingFxLayer(child.name), child, slot_active_flag_names);
                }
            }

            // Compensate avatar scaling on world offset (https://justsleightly.notion.site/Designing-Scale-Friendly-Systems-a5c9a9f9d4f24e60ab0503aeb2891b77)
            dbt.Add1D(dbt.Layer.FloatParameter("ScaleFactorInverse"), new[] {0.01f, 100f}, (clip, inv_scale) => {
                clip.Scaling(new[]{editor.pet_system_container.gameObject}, Vector3.one * inv_scale);
            });
        }
        private void RemoveAnimatorsPetSystems(ReplicatorAvatarAnimator editor, AacFlBase aac) {
            foreach(Transform child in editor.pet_system_container) {
                if (child.name.StartsWith("PetSystem")) {
                    aac.RemoveAllSupportingLayers(child.name);
                }
            }
        }
        private void CreateAnimatorPetSystem(AacFlBase aac, AacFlLayer layer, Transform system, List<string> slot_active_flag_names) {
            var constraint = system.GetComponent<ParentConstraint>();
            var raycast = system.Find("Raycast").gameObject;
            var renderer = system.GetComponentInChildren<MeshRenderer>(true);

            // Buttons, not synced
            var spawn_slow = layer.BoolParameter("PetSystem/SpawnSlow");
            var spawn_fast = layer.BoolParameter("PetSystem/SpawnFast");

            var slot_active_flag = layer.BoolParameter(system.name); // Is the pet slot in use, to select the next one to use. Synced here.
            var spawn_mode_synced = layer.BoolParameter("PetSystem/Fast"); // One bool, updated at the same time than the slot flag, to transmit spawn mode
            var physbone_grabbed = layer.BoolParameter($"{system.name}_IsGrabbed"); // not synced, replicated locally by physbone themselves

            var standby = layer.NewState("Standby")
                .Drives(slot_active_flag, false).DrivingLocally()
                .WithAnimation(aac.NewClip($"{system.name}_standby")
                    .TogglingComponent(constraint, true)
                    .Toggling(raycast, false)
                    .Scaling(new[]{raycast}, Vector3.one) // unpack scale, packed to keep sdk happy
                );

            // Whenever the pet is active, the physbone allows grabbing.
            // Grabbing transform override does its thing, just react to it.
            // Semantics are to "kill" the pet when grabbing, stopping its animation for good.

            // End of life, stays a few seconds before deactivation TODO add dislocation
            var dead = layer.NewState("Dead").Under(standby)
                .Drives(slot_active_flag, false).DrivingLocally() // reset flag
                .WithAnimation(aac.NewClip($"{system.name}_dead").Animating(clip => {
                    clip.Animates(renderer, "material._Replicator_Cower").WithOneFrame(0.9f);
                    clip.Animates(renderer, "material._Replicator_Dislocation_Time").WithSecondsUnit(keys => keys.Linear(0f, 0f).Linear(5f, 0f).Linear(5.5f, 0.5f));
                }));
            dead.AutomaticallyMovesTo(standby);

            // State is here to pause deactivation from end of life. Counter restarts when ungrabbed. Physbone handles position.
            var grabbed = layer.NewState("Grabbed").Under(dead)
                .WithAnimation(aac.NewClip($"{system.name}_grabbed").Animating(clip => {
                    clip.Animates(renderer, "material._Replicator_Cower").WithOneFrame(0.9f);
                    clip.Animates(renderer, "material._Replicator_Dislocation_Time").WithOneFrame(0f);
                }));
            dead.TransitionsTo(grabbed).When(physbone_grabbed.IsTrue());
            grabbed.TransitionsTo(dead).When(physbone_grabbed.IsFalse());

            const float shader_walking_speed_m_s = 0.4f; // from observations
            const float reach_m = 15f;

            foreach (var is_fast in new[]{false, true}) {
                string mode = is_fast ? "Fast" : "Slow";
                float walk_speed = is_fast ? 3f : 1f;
                var button = is_fast ? spawn_fast : spawn_slow;

                var debounce = layer.NewState($"Debounce {mode}").Shift(standby, is_fast ? 1 : -1, 0);

                var set_scale = layer.NewState($"Set Scale {mode}").Under(debounce).WithAnimation(
                    // Set to current scale at launch ; left constant during run.
                    DirectBlendTree.Create1D(aac, layer.FloatParameter("ScaleFactor"), new[] {0.01f, 100f}, (clip, scale) => {
                        clip.Scaling(new[]{system.gameObject}, Vector3.one * scale);
                    })
                );

                var active = layer.NewState($"Active {mode}").Under(set_scale)
                    .Drives(slot_active_flag, true)
                    .Drives(spawn_mode_synced, is_fast)
                    .DrivingLocally()
                    .WithAnimation(aac.NewClip($"{system.name}_active_{mode}")
                        .TogglingComponent(constraint, false)
                        .Toggling(raycast, true)
                        .Animating(clip => {
                            float t = reach_m / shader_walking_speed_m_s; // walk speed does not impact animation duration
                            AnimateTransformVec3(clip, raycast.transform, "m_LocalPosition", (curve, i) => {
                                if (i == 2) {
                                    // Walk on z
                                    curve.WithSecondsUnit(keys => keys.Linear(0f, 0f).Linear(t, reach_m * walk_speed));
                                } else {
                                    curve.WithOneFrame(0f); // TODO maybe random waving laterally ?
                                }
                            });
                            clip.Animates(renderer, "material._Replicator_Cower").WithOneFrame(0f);
                            clip.Animates(renderer, "material._Replicator_WalkSpeedFactor").WithOneFrame(walk_speed);
                            clip.Animates(renderer, "material._Replicator_Dislocation_Time").WithSecondsUnit(keys => keys.Linear(0f, 0.5f).Linear(0.5f, 0f).Constant(0.5f + frame_delay, 0f));
                        })
                    );

                var previous_slots_active = layer.BoolParameters(slot_active_flag_names.ToArray());
                standby.TransitionsTo(debounce).When(button.IsTrue()).And(previous_slots_active.AreTrue()); // select slot with priority, local only
                debounce.TransitionsTo(set_scale).When(button.IsFalse()); // debounce
                set_scale.AutomaticallyMovesTo(active);
                
                standby.TransitionsTo(active).When(slot_active_flag.IsTrue()).And(spawn_mode_synced.IsEqualTo(is_fast)); // remote path

                active.TransitionsTo(grabbed).WithTransitionDurationSeconds(2f).When(physbone_grabbed.IsTrue()); // Gradual cower
                active.TransitionsTo(dead).WithTransitionDurationSeconds(2f).AfterAnimationFinishes();
            }

            slot_active_flag_names.Add(slot_active_flag.Name);
        }

        //////////////////////////////////////////////////////////////////////////////////////////////////////////////////

        private void CreateAnimatorAnchor(ReplicatorAvatarAnimator editor, DirectBlendTree dbt) {
            var collider = editor.remote_anchor.GetComponent<BoxCollider>();
            string blendshape = "Deploy_Remote_Anchor";

            // Nested tree when enabled
            BlendTree enabled_with_position = DirectBlendTree.Create1D(dbt.Aac, dbt.Layer.FloatParameter("Remote/Distance"), new[] {0f, 1f}, (clip, distance) => {
                clip.TogglingComponent(collider, true);
                clip.BlendShape(editor.main_mesh, blendshape, 100f);
                clip.Animating(clip => {
                    AnimateTransformVec3(clip, editor.remote_anchor, "m_LocalPosition", (curve, i) => {
                            curve.WithOneFrame(i == 1 ? distance * 40f + 0.21f : 0f); // y, with shift to show the anchor widget
                    });
                });
            });

            dbt.Add1D(
                dbt.Layer.FloatParameter("Remote/Enabled"),
                new[] {0f, 1f},
                enabled => {
                    if (enabled < 0.5) {
                        var clip = dbt.Aac.NewClip("Remote_Disabled");
                        clip.TogglingComponent(collider, false);
                        clip.BlendShape(editor.main_mesh, blendshape, 0f);
                        clip.Animating(clip =>{
                            AnimateTransformVec3(clip, editor.remote_anchor, "m_LocalPosition", (curve, i) => {
                                curve.WithOneFrame(0f);
                            });
                        });
                        return clip.Clip;
                    } else {
                        return enabled_with_position;
                    }
                }
            );
        }

        //////////////////////////////////////////////////////////////////////////////////////////////////////////////////

        // We have many constraints with constraints with only one source active at a time.
        // Animations with change of active source require a lot of clutter, with one animated parameter per source weight (1 -> 0, 0 -> 1).
        // These few functions remove the clutter by creating the set of replicated curves with start / end values depending on index.
        
        // Typing, and quickly generate {0,1} floats by comparing to active source
        private struct ActiveSource {
            public readonly int i;
            public ActiveSource(int init) { i = init; }
            static public float operator==(ActiveSource s, int i) => s.i == i ? 1 : 0;
            static public float operator!=(ActiveSource s, int i) => throw new Exception("required but makes no sense");
            public override bool Equals(object obj) { throw new System.NotImplementedException(); }
            public override int GetHashCode() { throw new System.NotImplementedException(); }
        }
        // Base function, duplicates curve for each source weight
        static private void AnimateConstraintSources(AacFlEditClip clip, Component constraint, int source_count, Action<AacFlSettingCurve, ActiveSource> edit) {
            for (int i = 0; i < source_count; i += 1) {
                edit.Invoke(clip.Animates(constraint, $"m_Sources.Array.data[{i}].weight"), new ActiveSource(i));
            }
        }
        // Nice overloads that infer source count from concrete type
        static private void AnimateConstraintSources(AacFlEditClip clip, ParentConstraint constraint, Action<AacFlSettingCurve, ActiveSource> edit) {
            AnimateConstraintSources(clip, constraint, constraint.sourceCount, edit);
        }
        static private void AnimateConstraintSources(AacFlEditClip clip, RotationConstraint constraint, Action<AacFlSettingCurve, ActiveSource> edit) {
            AnimateConstraintSources(clip, constraint, constraint.sourceCount, edit);
        }
        static private void AnimateConstraintSources(AacFlEditClip clip, ScaleConstraint constraint, Action<AacFlSettingCurve, ActiveSource> edit) {
            AnimateConstraintSources(clip, constraint, constraint.sourceCount, edit);
        }

        //////////////////////////////////////////////////////////////////////////////////////////////////////////////////

        // Animate a transform vec3. Creates 3 curves for x,y,z
        static private void AnimateTransformVec3(AacFlEditClip clip, Transform transform, string property, Action<AacFlSettingCurve, int> edit) {
            string[] coord_suffix = {"x", "y", "z"};
            for (int i = 0; i < 3; i += 1) {
                edit.Invoke(clip.Animates(transform, typeof(Transform), $"{property}.{coord_suffix[i]}"), i);
            }
        }

        //////////////////////////////////////////////////////////////////////////////////////////////////////////////////

        // GUI hook
        public override void OnInspectorGUI() {
            var prop = serializedObject.FindProperty("assetKey");
            if (prop.stringValue.Trim() == ""){
                prop.stringValue = GUID.Generate().ToString();
                serializedObject.ApplyModifiedProperties();
            }

            DrawDefaultInspector();

            if (GUILayout.Button("Create")) { Create(); }
            if (GUILayout.Button("Remove")) { Remove(); }
        }

        /// <summary>
        /// Creates an AAC base. This function is provided as an example on how to invoke AAC internals.
        /// </summary>
        /// <param name="systemName">Prefix for layer names</param>
        /// <param name="avatar">Playable layers of this avatar to modify</param>
        /// <param name="assetContainer">Animation assets will be generated as sub-assets of that asset container</param>
        /// <param name="assetKey">Animation assets will be generated with this name in order to clean up previously generated assets of the same system</param>
        /// <param name="options">Some options, such as whether Write Defaults is ON or OFF</param>
        /// <returns>The AAC base.</returns>
        private AacFlBase AnimatorAsCode(ReplicatorAvatarAnimator editor) {
            var aac = AacV0.Create(new AacConfiguration {
                SystemName = "A",
                // In the examples, we consider the avatar to be also the animator root.
                AvatarDescriptor = editor.avatar,
                // You can set the animator root to be different than the avatar descriptor,
                // if you want to apply an animator to a different avatar without redefining
                // all of the game object references which were relative to the original avatar.
                AnimatorRoot = editor.avatar.transform,
                // DefaultValueRoot is currently unused in AAC. It is added here preemptively
                // in order to define an avatar root to sample default values from.
                // The intent is to allow animators to be created with Write Defaults OFF,
                // but mimicking the behaviour of Write Defaults ON by automatically
                // sampling the default value from the scene relative to the transform
                // defined in DefaultValueRoot.
                DefaultValueRoot = editor.avatar.transform,
                AssetContainer = editor.assetContainer,
                AssetKey = editor.assetKey,
                DefaultsProvider = new AacDefaultsProvider(writeDefaults: false)
            });
            aac.ClearPreviousAssets();
            return aac;
        }
    }

    class DirectBlendTree {
        private readonly BlendTree _tree;
        private readonly AacFlLayer _layer;
        private readonly AacFlBase _aac;

        public AacFlLayer Layer {
            get { return _layer; }
        }
        public AacFlBase Aac {
            get { return _aac; }
        }

        public DirectBlendTree(AacFlBase aac) {
            _aac = aac;
            // Create a direct blend tree to package all parallel blend trees used later on.
            // Better for performance compared to many layers : https://notes.sleightly.dev/benchmarks/
            _tree = aac.NewBlendTreeAsRaw();
            _tree.blendType = UnityEditor.Animations.BlendTreeType.Direct;

            _layer = aac.CreateSupportingFxLayer("DBT");
            _layer.NewState("DBT")
                .WithWriteDefaultsSetTo(true) // Required for direct blend tree to work nice : https://notes.sleightly.dev/dbt-combining/
                .WithAnimation(_tree);
        }

        public void Add(BlendTree child) {
            var new_children = new ChildMotion[_tree.children.Length + 1];
            _tree.children.CopyTo(new_children, 0);
            new_children[new_children.Length - 1] = new ChildMotion {motion = child, timeScale = 1, directBlendParameter = "DBT_Weight"};
            _tree.children = new_children;
        }

        // Create a blend tree with >=2 animations min/max blended with parameter. Not bound to anything
        static public BlendTree Create1D(AacFlBase aac, AacFlFloatParameter parameter, float[] blend_values, Func<float, Motion> create_clip) {
            Debug.Assert(blend_values.Length >= 2);
            Array.Sort(blend_values);
            float min = blend_values.Min();
            float max = blend_values.Max();
            Debug.Assert(min < max);

            var tree = aac.NewBlendTreeAsRaw();
            tree.blendType = BlendTreeType.Simple1D;
            tree.blendParameter = parameter.Name;
            tree.minThreshold = min;
            tree.maxThreshold = max;
            tree.useAutomaticThresholds = false;

            ChildMotion make_clip(float blend_value) {
                return new ChildMotion{motion = create_clip(blend_value), timeScale = 1, threshold = blend_value};
            }
            tree.children = blend_values.Select(blend => make_clip(blend)).ToArray();
            return tree;
        }
        // Shorthand for just editing an animation that is already created and named
        static public BlendTree Create1D(AacFlBase aac, AacFlFloatParameter parameter, float[] blend_values, Action<AacFlClip, float> setup_clip) {
            int i = 0;
            Motion create_clip(float blend_value) {
                var clip = aac.NewClip($"{parameter.Name.Replace('/', '_')}_{i}");
                i += 1; // Just here to easily name cases
                setup_clip.Invoke(clip, blend_value);
                return clip.Clip;
            }
            return Create1D(aac, parameter, blend_values, create_clip);
        }

        // Create 1d blendtree and add to dbt layer
        public void Add1D(AacFlFloatParameter parameter, float[] blend_values, Action<AacFlClip, float> setup_clip) {
            Add(Create1D(_aac, parameter, blend_values, setup_clip));
        }
        public void Add1D(AacFlFloatParameter parameter, float[] blend_values, Func<float, Motion> create_clip) {
            Add(Create1D(_aac, parameter, blend_values, create_clip));
        }
    }
}
#endif