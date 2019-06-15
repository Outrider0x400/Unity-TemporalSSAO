using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

//#pragma warning disable 0649

[ExecuteInEditMode]
[RequireComponent(typeof(Camera))]
public class TemporalScalableAmbientObscurance : MonoBehaviour
{
    Camera localCamera_;

    CommandBuffer mainBuffer_;
    const CameraEvent computeInsertion = CameraEvent.BeforeImageEffects;
    CommandBuffer blitBuffer_;
    const CameraEvent blitInsertion = CameraEvent.BeforeImageEffects;
    CommandBuffer debugBuffer_;
    const CameraEvent debugInsertion = CameraEvent.AfterEverything;

    RenderTexture aoResultRt_;
    RenderTexture prevAoResultRt_;
    RenderTexture prevFrameDepthRt_;

    // 2 temporay RTs' ids
    int rawResultRtId_, xBlurredRtId_;

    RenderTextureDescriptor aoDescriptor_;

    [SerializeField] private bool debugMode = false;
    private bool debugMode_ = false; 


    [Range(0.01f, 5.0f)]
    [Tooltip("World space distance of the sphere of influence.")]
    public float radius = 1.0f;
    [Range(0.0f, 1.0f)]
    [Tooltip("Adaptive depth bias. Increase to suppress depth artifacts.")]
    public float bias = 0.001f;
    [Range(0.0f, 1.0f)]
    [Tooltip("Distance threshold that determines whether a reprojected fragment is disoccluded.")]
    public float disocclusionThreshold = 0.02f;
    [Range(0.0f, 1.0f)]
    [Tooltip("Fixed bias for disocclusion check.")]
    public float disocclusionBias = 0.02f;
    [Range(0.0f, 1.0f)]
    [Tooltip("Threshold for neighbourhood change detection. Increase if ghosting is too severe.")]
    public float neighbourhoodChangeThreshold = 0.02f;
    [Range(0.0f, 1.0f)]
    [Tooltip("Fixed bias for neighbourhood change detection.")]
    public float neighbourhoodChangeBias = 0.02f;
    [Range(0.0f, 1.0f)]
    [Tooltip("A invalidated fragment starts with this value as its temporal weight.")]
    public float startingTemporalWeight = 0.1f;
    [Range(0.0f, 1.0f)]
    [Tooltip("Increase in case of ghosting. Decrease for less flickering.")]
    public float temporalConvergenceRate = 0.05f;

    public Shader shader;
    Material tsaoMaterial;
    Matrix4x4 lastViewMatrix_;

    bool CheckForValidation()
    {
        if (debugMode_ != debugMode)
        {
            debugMode_ = debugMode;
            return true;
        }

        return false;
    }

    private void Update()
    {
        if (CheckForValidation())
        {
            Initialize(debugMode_);
        }
        
    }

    private void OnPreRender()
    {
        if (tsaoMaterial != null)
        {
            // Used to convert points/vevectors back into view space
            UpdateFrustumCorner_();
            
            tsaoMaterial.SetFloat("_BaselineDepthBias", bias);
            tsaoMaterial.SetFloat("_WorldSpaceRadius", radius);

            // Used to determine the size of the projection of the disk
            tsaoMaterial.SetFloat("_TanHalfFoV", Mathf.Tan(localCamera_.fieldOfView * Mathf.Deg2Rad));

            tsaoMaterial.SetFloat("_AspectRatio", localCamera_.aspect);

            tsaoMaterial.SetFloat("_DisocclusionThreshold", disocclusionThreshold);
            tsaoMaterial.SetFloat("_DisocclusionBias", disocclusionBias);
            tsaoMaterial.SetFloat("_NeiChangeBias", neighbourhoodChangeBias);
            tsaoMaterial.SetFloat("_NeiChangeThreshold", neighbourhoodChangeThreshold);
            tsaoMaterial.SetFloat("_StartingTemporalWeight", startingTemporalWeight);
            tsaoMaterial.SetFloat("_WeightStep", temporalConvergenceRate);

            tsaoMaterial.SetMatrix("_InvViewMatrix", (localCamera_.cameraToWorldMatrix));
            tsaoMaterial.SetMatrix("_LastViewMatrix", lastViewMatrix_);
            tsaoMaterial.SetMatrix("_ViewMatrix", localCamera_.worldToCameraMatrix);
        }
    }

    float lastFrustumCornerX_, lastFrustumCornerY_;
    private void UpdateFrustumCorner_()
    {
        // Assuming for symmertircal projection
        var corners = new Vector3[4];
        localCamera_.CalculateFrustumCorners(new Rect(0, 0, 1, 1), localCamera_.nearClipPlane, Camera.MonoOrStereoscopicEye.Mono, corners);
        tsaoMaterial.SetFloat("_FrustumCornerX", corners[2][0]);
        tsaoMaterial.SetFloat("_FrustumCornerY", corners[2][1]);

        // Send the data from last CPU cycle to GPU
        tsaoMaterial.SetFloat("_LastFrustumCornerX", lastFrustumCornerX_);
        tsaoMaterial.SetFloat("_LastFrustumCornerY", lastFrustumCornerY_);

        // There will be sent next time this method is called
        lastFrustumCornerX_ = corners[2][0];
        lastFrustumCornerY_ = corners[2][1];
    }

    private void OnEnable()
    {
        localCamera_ = GetComponent<Camera>();
        Initialize(debugMode_);
    }

    private void Initialize(bool debug)
    {
        if (shader == null)
        {
            Debug.Log("Shader not detected. Please assign the shader file to this component.");
            return;
        }

        if (localCamera_.renderingPath != RenderingPath.DeferredShading)
        {
            Debug.Log("Deferred shading is required for this effect.");
            return;
        }

        if (!localCamera_.allowHDR)
        {
            Debug.Log("HDR is required for this effect.");
            return;
        }
        
        localCamera_.depthTextureMode = DepthTextureMode.MotionVectors | DepthTextureMode.Depth;
        

        tsaoMaterial = new Material(shader);
        

        DestroyComputeBuffer();
        DestroyDebugCommandBuffer();

        aoDescriptor_ = new RenderTextureDescriptor(localCamera_.pixelWidth, localCamera_.pixelHeight, RenderTextureFormat.RG16, 0);
        

        if (aoResultRt_ != null)
            aoResultRt_.Release();
        aoResultRt_ = new RenderTexture(aoDescriptor_);
        // The engine gives me error sometime that I set it to zero, while I did not set it at all. So, here you go. It's 1. I said it.
        aoResultRt_.antiAliasing = 1;
        aoResultRt_.Create();

        if (prevAoResultRt_ != null)
            prevAoResultRt_.Release();
        prevAoResultRt_ = new RenderTexture(aoDescriptor_);
        prevAoResultRt_.antiAliasing = 1;
        prevAoResultRt_.Create();

        if (prevFrameDepthRt_ != null)
            prevFrameDepthRt_.Release();
        // Setting the format to Depth seems to be problematic
        prevFrameDepthRt_ = new RenderTexture(localCamera_.pixelWidth, localCamera_.pixelHeight, 0, RenderTextureFormat.RFloat);
        prevFrameDepthRt_.Create();

        // give it an init value for the first frame
        lastViewMatrix_ = localCamera_.worldToCameraMatrix;

        rawResultRtId_ = Shader.PropertyToID("_AoRawResultRtTemp_");
        xBlurredRtId_ = Shader.PropertyToID("_AoXBlurredResultRtTemp_");



        BuildComputeBuffer();
        if (debugMode_)
            BuildDebugCommandBuffer();
    }

    void OnDisable()
    {

        DestroyComputeBuffer();
        
        DestroyDebugCommandBuffer();
        
    }




    void BuildDebugCommandBuffer()
    {
        debugBuffer_ = new CommandBuffer();
        debugBuffer_.name = "DebugBlitCommandBuffer";


        debugBuffer_.SetGlobalTexture("_FinalAoResult", aoResultRt_);
        debugBuffer_.Blit(null, BuiltinRenderTextureType.CameraTarget, tsaoMaterial, 1);

        localCamera_.AddCommandBuffer(debugInsertion, debugBuffer_);
    }
    void DestroyDebugCommandBuffer()
    {
        
        if (debugBuffer_ != null)
            localCamera_.RemoveCommandBuffer(debugInsertion, debugBuffer_);
    }

    void BuildComputeBuffer()
    {
        mainBuffer_ = new CommandBuffer();
        mainBuffer_.name = "TemporalScalableAmbientObscuranceComputeBuffer";

        mainBuffer_.SetGlobalTexture("_CameraDepthTexturePrev", prevFrameDepthRt_);
        mainBuffer_.SetGlobalTexture("_AoResultPrev", prevAoResultRt_);

        // The computation
        mainBuffer_.GetTemporaryRT(rawResultRtId_, localCamera_.pixelWidth, localCamera_.pixelHeight, 0, FilterMode.Point, RenderTextureFormat.RG16,
            RenderTextureReadWrite.Default, 1);
        mainBuffer_.Blit(null, rawResultRtId_, tsaoMaterial, 0);

        // X blur
        mainBuffer_.GetTemporaryRT(xBlurredRtId_, localCamera_.pixelWidth, localCamera_.pixelHeight, 0, FilterMode.Point, RenderTextureFormat.RG16,
            RenderTextureReadWrite.Default, 1);
        mainBuffer_.SetGlobalInt("_StepX", 1); mainBuffer_.SetGlobalInt("_StepY", 0);
        mainBuffer_.Blit(rawResultRtId_, xBlurredRtId_, tsaoMaterial, 2);
        mainBuffer_.ReleaseTemporaryRT(rawResultRtId_);

        // Y Blur
        mainBuffer_.SetGlobalInt("_StepX", 0); mainBuffer_.SetGlobalInt("_StepY", 1);
        mainBuffer_.Blit(xBlurredRtId_, aoResultRt_, tsaoMaterial, 2);
        mainBuffer_.ReleaseTemporaryRT(xBlurredRtId_);

        // Store for the next frame
        mainBuffer_.Blit(BuiltinRenderTextureType.ResolvedDepth, prevFrameDepthRt_);
        mainBuffer_.CopyTexture(aoResultRt_, prevAoResultRt_);

        if (!debugMode_)
        {
            RenderTargetIdentifier[] compositeRenderTargets = {
                BuiltinRenderTextureType.GBuffer0,
                BuiltinRenderTextureType.CameraTarget
            };
            mainBuffer_.SetGlobalTexture("_FinalAoResult", aoResultRt_);
            mainBuffer_.SetRenderTarget(compositeRenderTargets, BuiltinRenderTextureType.CameraTarget);
            mainBuffer_.DrawProcedural(Matrix4x4.identity, tsaoMaterial, 3, MeshTopology.Triangles, 3);
        }

        localCamera_.AddCommandBuffer(computeInsertion, mainBuffer_);
    }
    private void DestroyComputeBuffer()
    {

        if (mainBuffer_ != null)
            localCamera_.RemoveCommandBuffer(computeInsertion, mainBuffer_);
    }

    private void OnPostRender()
    {
        lastViewMatrix_ = localCamera_.worldToCameraMatrix;

    }
}
