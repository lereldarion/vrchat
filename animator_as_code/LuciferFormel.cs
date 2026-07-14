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

[assembly: ExportsPlugin(typeof(Lereldarion.LuciferFormelPlugin))]

namespace Lereldarion {
    public class LuciferFormel : MonoBehaviour, IEditorOnly {
        public VRCExpressionsMenu menu_target;

        [Header("Jacket toggle")]
        public SkinnedMeshRenderer jacket;
        public SkinnedMeshRenderer shirt;
    }

    public class LuciferFormelPlugin : Plugin<LuciferFormelPlugin> {
        public override string DisplayName => "Lucifer Formel Animator";

        public string SystemName => "LuciferFormel";

        protected override void Configure() {
            InPhase(BuildPhase.Generating).Run(DisplayName, Generate);
        }

        private void Generate(BuildContext ctx) {
            var config = ctx.AvatarRootTransform.GetComponentInChildren<LuciferFormel>(true);
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
                installer.installTargetMenu = config.menu_target;
                return ma.EditMenuItem(menu);
            }

            // 1 toggle : jacket + shrinking blenshape for shirt under it

            var ctrl = aac.NewAnimatorController();
            {
                var layer = ctrl.NewLayer("Jacket Toggle");

                var parameter = layer.FloatParameter("Jacket");
                ma.NewBoolToFloatParameter(parameter).WithDefaultValue(true);
                new_installed_menu_item().Name("Jacket").ToggleBoolToFloat(parameter); 

                var tree = aac.NewBlendTree().Simple1D(parameter);
                foreach(var enabled in new[]{true, false}) {
                    var clip = aac.NewClip();
                    clip.Toggling(config.jacket.gameObject, enabled);
                    clip.BlendShape(config.shirt, "Shrink_jacket", enabled ? 100 : 0);
                    tree.WithAnimation(clip, enabled ? 1 : 0);
                }
                layer.NewState("Tree").WithAnimation(tree);
            }
            ma.NewMergeAnimator(ctrl.AnimatorController, VRCAvatarDescriptor.AnimLayerType.FX);
        }
    }
}
#endif