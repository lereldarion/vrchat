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

[assembly: ExportsPlugin(typeof(Lereldarion.Aac.MaterialSwapGeneratorPlugin))]

namespace Lereldarion.Aac
{
    public class MaterialSwapGenerator : MonoBehaviour, IEditorOnly
    {
        [Header("Menu")]
        public VRCExpressionsMenu MenuTarget = null;
        public string ParameterName = "Color";
        public string MenuName = "Color";

        [Header("Material slots")]
        public Renderer[] Renderers;
        public int[] MaterialSlots;
        [Tooltip("[Swap 0 = material [0, 1, 2] | Swap 1 = material [0, 1, 2] | ... ]")]
        public Material[] Materials;
    }

    public class MaterialSwapGeneratorPlugin : Plugin<MaterialSwapGeneratorPlugin>
    {
        public override string DisplayName => "Material Swap Generator";

        public string SystemName => "Lereldarion.Aac.MaterialSwapGenerator";

        protected override void Configure()
        {
            InPhase(BuildPhase.Generating).Run(DisplayName, Generate);
        }

        private void Generate(BuildContext ctx)
        {
            MaterialSwapGenerator[] material_swaps = ctx.AvatarRootTransform.GetComponentsInChildren<MaterialSwapGenerator>(true);
            if (material_swaps.Length == 0) { return; }

            AacFlBase aac = AacV1.Create(new AacConfiguration
            {
                SystemName = SystemName,
                AnimatorRoot = ctx.AvatarRootTransform,
                DefaultValueRoot = ctx.AvatarRootTransform,
                AssetKey = GUID.Generate().ToString(),
                AssetContainer = ctx.AssetContainer,
                ContainerMode = AacConfiguration.Container.OnlyWhenPersistenceRequired,
                DefaultsProvider = new AacDefaultsProvider()
            });

            AacFlController ctrl = aac.NewAnimatorController();
            GameObject ma_object = new GameObject(SystemName) { transform = { parent = ctx.AvatarRootTransform } };
            MaAc modular_avatar = MaAc.Create(ma_object);

            foreach (MaterialSwapGenerator material_swap in material_swaps)
            {
                int slot_count = material_swap.MaterialSlots.Length;
                if (slot_count != material_swap.Renderers.Length)
                {
                    throw new System.Exception("renderer and material slot lists must match");
                }
                if (slot_count == 0) { continue; } // Skip
                int variant_count = material_swap.Materials.Length / slot_count;
                if (variant_count * slot_count < material_swap.Materials.Length)
                {
                    throw new System.Exception("material list must be swap_count * slot_count long");
                }

                AacFlLayer layer = ctrl.NewLayer(material_swap.MenuName);
                AacFlFloatParameter parameter = layer.FloatParameter(material_swap.ParameterName);

                // Modular avatar param + menu
                {
                    modular_avatar.NewParameter(parameter).WithDefaultValue(0);

                    GameObject menu = new GameObject { transform = { parent = ma_object.transform } };
                    ModularAvatarMenuInstaller installer = menu.AddComponent<ModularAvatarMenuInstaller>();
                    installer.installTargetMenu = material_swap.MenuTarget;
                    MaacMenuItem item = modular_avatar.EditMenuItem(menu);
                    item.Name(material_swap.MenuName);
                    item.Radial(parameter);
                }

                AacFlBlendTree1D tree = aac.NewBlendTree().Simple1D(parameter);

                for (int variant = 0; variant < variant_count; variant += 1)
                {
                    var clip = aac.NewClip();
                    for (int slot = 0; slot < slot_count; slot += 1)
                    {
                        clip.SwappingMaterial(material_swap.Renderers[slot], material_swap.MaterialSlots[slot], material_swap.Materials[variant * slot_count + slot]);
                    }
                    tree.WithAnimation(clip, ((float)variant) / (variant_count - 1));
                }
                layer.NewState("Tree").WithAnimation(tree);
            }

            modular_avatar.NewMergeAnimator(ctrl.AnimatorController, VRCAvatarDescriptor.AnimLayerType.FX);

            // Cleanup components
            foreach (MaterialSwapGenerator material_swap in material_swaps) { Object.DestroyImmediate(material_swap); }
        }
    }
}
#endif