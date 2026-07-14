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

[assembly: ExportsPlugin(typeof(Lereldarion.Aac.ToggleGeneratorPlugin))]

namespace Lereldarion.Aac {
    public class ToggleGenerator : MonoBehaviour, IEditorOnly {
        public VRCExpressionsMenu MenuTarget;
        public string MenuName;
        public string ParameterName;
        public bool DefaultState = false;
        public bool Saved = false;

        [Header("Items")]
        public GameObject[] GameobjectsOn;
        public GameObject[] GameobjectsOff;
        public Component[] ComponentsOn;
        public Component[] ComponentsOff;
    }

    public class ToggleGeneratorPlugin : Plugin<ToggleGeneratorPlugin> {
        public override string DisplayName => "Toggle Generator";

        public string SystemName => "Lereldarion.Aac.ToggleGenerator";

        protected override void Configure() {
            InPhase(BuildPhase.Generating).Run(DisplayName, Generate);
        }

        private void Generate(BuildContext ctx) {
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
            MaacMenuItem new_installed_menu_item(VRCExpressionsMenu target) {
                var menu = new GameObject { transform = { parent = ma_object.transform }};
                var installer = menu.AddComponent<ModularAvatarMenuInstaller>();
                installer.installTargetMenu = target;
                return ma.EditMenuItem(menu);
            }
            var ctrl = aac.NewAnimatorController();

            foreach (var toggle in ctx.AvatarRootTransform.GetComponentsInChildren<ToggleGenerator>())
            {
                var layer = ctrl.NewLayer(toggle.MenuName);
                var parameter = layer.BoolParameter(toggle.ParameterName);
                var ma_parameter = ma.NewParameter(parameter);
                ma_parameter.WithDefaultValue(toggle.DefaultState);
                if(toggle.Saved == false) ma_parameter.NotSaved();
                new_installed_menu_item(toggle.MenuTarget).Name(toggle.MenuName).Toggle(parameter);

                AacFlClip clip_for(bool state)
                {
                    var clip = aac.NewClip();
                    foreach(var g in toggle.GameobjectsOn) clip.Toggling(g, state);
                    foreach(var g in toggle.GameobjectsOff) clip.Toggling(g, !state);
                    foreach(var c in toggle.ComponentsOn) clip.TogglingComponent(c, state);
                    foreach(var c in toggle.ComponentsOff) clip.TogglingComponent(c, !state);
                    return clip;
                }

                var off = layer.NewState("Off").WithAnimation(clip_for(false));
                var on = layer.NewState("On").WithAnimation(clip_for(true));

                off.TransitionsTo(on).When(parameter.IsTrue());
                on.TransitionsTo(off).When(parameter.IsFalse());
            }

            ma.NewMergeAnimator(ctrl.AnimatorController, VRCAvatarDescriptor.AnimLayerType.FX);
        }
    }
}
#endif