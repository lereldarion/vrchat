#if UNITY_EDITOR
using AnimatorAsCode.V1;
using AnimatorAsCode.V1.ModularAvatar;
using AnimatorAsCode.V1.VRC;
using nadena.dev.modular_avatar.core;
using nadena.dev.ndmf;
using UnityEditor;
using UnityEngine;
using VRC.SDK3.Avatars.Components;
using VRC.SDK3.Avatars.ScriptableObjects;
using VRC.SDK3.Dynamics.Constraint.Components;
using VRC.SDKBase;

[assembly: ExportsPlugin(typeof(Lereldarion.LuciferGlassesPlugin))]

namespace Lereldarion {
    public class LuciferGlasses : MonoBehaviour, IEditorOnly {
        public VRCExpressionsMenu menu_target;

        [Header("Glasses position")]
        public VRCParentConstraint relocator;
        public VRCHeadChop fpv_scale_control;
        public Motion hand_gesture;

        [Header("Overlay")]
        public Renderer overlay_renderer;
        public Material[] overlays;
        public Material gamma_adjust_overlay;
    }

    public class LuciferGlassesPlugin : Plugin<LuciferGlassesPlugin> {
        public override string DisplayName => "Lucifer Glasses Animator";

        public string SystemName => "LuciferGlasses";

        protected override void Configure() {
            InPhase(BuildPhase.Generating).Run(DisplayName, Generate);
        }

        private void Generate(BuildContext ctx) {
            var config = ctx.AvatarRootTransform.GetComponentInChildren<LuciferGlasses>(true);
            if(config == null) { return; }

            // Fix mesh bounds to prevent renderer culling at certain angles.
            // This is necessary because the lens renderer is not merged into the main skinnedmeshrenderer, due to material swap animations.
            // Centered 50cm cube should be enough.
            config.overlay_renderer.GetComponent<MeshFilter>().sharedMesh.bounds = new Bounds(Vector3.zero, 0.5f * Vector3.one);

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
                installer.installTargetMenu = config.menu_target;
                return ma.EditMenuItem(menu);
            }

            var fx = aac.NewAnimatorController();
            var gesture = aac.NewAnimatorController();

            // Overlay shader control
            {
                var layer = fx.NewLayer("Glasses Overlay");

                var parameter = layer.FloatParameter("Overlay");
                ma.NewParameter(parameter).NotSaved().WithDefaultValue(0);
                new_installed_menu_item().Name("Overlay").Radial(parameter);

                // Radial control is [0,1].
                // Use [0, gamma_start] for selecting non-parametric overlays
                // Use [gamma_start, 1] for controlling gamma on gamma adjust overlay 
                const float gamma_start = 0.5f;
                var states = new AacFlState[config.overlays.Length + 1];

                // Non parametric overlays. Defaults to 0 == hidden.
                for(int i = 0; i < config.overlays.Length; i += 1) {
                    var state = layer.NewState($"Overlay {i}");
                    var clip = aac.NewClip();
                    clip.SwappingMaterial(config.overlay_renderer, 0, config.overlays[i]);
                    clip.TogglingComponent(config.overlay_renderer, i != 0); // Disable renderer if not needed
                    state.WithAnimation(clip);
                    states[i] = state;
                }

                // Gamma Adjust
                var gamma_tree = aac.NewBlendTree().Simple1D(parameter);
                gamma_tree.WithAnimation(
                    aac.NewClip()
                        .SwappingMaterial(config.overlay_renderer, 0, config.gamma_adjust_overlay)
                        .Animating(edit => edit.Animates(config.overlay_renderer, "material._Gamma_Adjust_Value").WithOneFrame(3)),
                    gamma_start
                );
                gamma_tree.WithAnimation(
                    aac.NewClip()
                        .SwappingMaterial(config.overlay_renderer, 0, config.gamma_adjust_overlay)
                        .Animating(edit => edit.Animates(config.overlay_renderer, "material._Gamma_Adjust_Value").WithOneFrame(-3)),
                    1
                );
                states[config.overlays.Length] = layer.NewState("Gamma Adjust").WithAnimation(gamma_tree);

                // Transitions
                for(int switch_point = 0; switch_point < config.overlays.Length; switch_point += 1) {
                    int under = switch_point;
                    int over = switch_point + 1;
                    float offset = gamma_start * (switch_point + 1) / config.overlays.Length;
                    states[under].TransitionsTo(states[over]).When(parameter.IsGreaterThan(offset));
                    states[over].TransitionsTo(states[under]).When(parameter.IsLessThan(offset));
                }
            }
            
            // Position
            string synced_in_hand = "Glasses/InHand";
            {
                var layer = fx.NewLayer("Glasses Position");

                var contact = layer.BoolParameter("Glasses/Contact");
                var synced = layer.BoolParameter(synced_in_hand);
                ma.NewParameter(synced).WithDefaultValue(false).NotSaved();

                var is_local = layer.NewState("IsLocal");

                // local
                var on_head_local = layer.NewState("Head Local");
                on_head_local.Drives(synced, false);
                on_head_local.WithAnimation(aac.NewClip().Animating(clip => {
                    clip.Animates(config.relocator, "Sources.source0.Weight").WithOneFrame(1);
                    clip.Animates(config.relocator, "Sources.source1.Weight").WithOneFrame(0);
                    clip.Animates(config.fpv_scale_control, "globalScaleFactor").WithOneFrame(0);
                    clip.Animates(config.overlay_renderer, "material._Overlay_Fullscreen").WithOneFrame(1);
                }));

                var in_hand_local = layer.NewState("Hand Local");
                in_hand_local.Drives(synced, true);
                in_hand_local.WithAnimation(aac.NewClip().Animating(clip => {
                    clip.Animates(config.relocator, "Sources.source0.Weight").WithOneFrame(0);
                    clip.Animates(config.relocator, "Sources.source1.Weight").WithOneFrame(1);
                    clip.Animates(config.fpv_scale_control, "globalScaleFactor").WithOneFrame(1);
                    clip.Animates(config.overlay_renderer, "material._Overlay_Fullscreen").WithOneFrame(0);
                }));

                is_local.TransitionsTo(on_head_local).When(layer.Av3().ItIsLocal());
                on_head_local.TransitionsTo(in_hand_local).WithTransitionDurationSeconds(0.2f)
                    .When(contact.IsTrue()).And(layer.Av3().GestureRight.IsEqualTo(AacAv3.Av3Gesture.Fist));
                in_hand_local.TransitionsTo(on_head_local).WithTransitionDurationSeconds(0.2f)
                    .When(contact.IsTrue()).And(layer.Av3().GestureRight.IsEqualTo(AacAv3.Av3Gesture.HandOpen));

                // remote
                var on_head_remote = layer.NewState("Head Remote");
                on_head_remote.WithAnimation(aac.NewClip().Animating(clip => {
                    clip.Animates(config.relocator, "Sources.source0.Weight").WithOneFrame(1);
                    clip.Animates(config.relocator, "Sources.source1.Weight").WithOneFrame(0);
                }));

                var in_hand_remote = layer.NewState("Hand Remote");
                in_hand_remote.WithAnimation(aac.NewClip().Animating(clip => {
                    clip.Animates(config.relocator, "Sources.source0.Weight").WithOneFrame(0);
                    clip.Animates(config.relocator, "Sources.source1.Weight").WithOneFrame(1);
                }));

                is_local.TransitionsTo(on_head_remote).When(layer.Av3().ItIsRemote());
                on_head_remote.TransitionsTo(in_hand_remote).WithTransitionDurationSeconds(0.2f).When(synced.IsTrue());
                in_hand_remote.TransitionsTo(on_head_remote).WithTransitionDurationSeconds(0.2f).When(synced.IsFalse());
            }
            {
                var layer = gesture.NewLayer("Glasses Hand Grab");
                layer.WithAvatarMask(aac.VrcAssets().RightHandAvatarMask());

                var synced = layer.BoolParameter(synced_in_hand);

                var disabled = layer.NewState("Disabled");
                disabled.TrackingTracks(AacAv3.Av3TrackingElement.RightFingers);

                var enabled = layer.NewState("Enabled");
                enabled.TrackingAnimates(AacAv3.Av3TrackingElement.RightFingers);
                // had to manually delete blendshapes after import, to prevent overriding visemes
                enabled.WithAnimation(config.hand_gesture);

                disabled.TransitionsTo(enabled).When(synced.IsTrue());
                enabled.TransitionsTo(disabled).When(synced.IsFalse());
            }


            ma.NewMergeAnimator(fx.AnimatorController, VRCAvatarDescriptor.AnimLayerType.FX);
            ma.NewMergeAnimator(gesture.AnimatorController, VRCAvatarDescriptor.AnimLayerType.Gesture);
        }
    }
}
#endif