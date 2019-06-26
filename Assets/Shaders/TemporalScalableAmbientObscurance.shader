Shader "Hidden/TemporalScalableAmbientObscurance"
{
    Properties
    {
		_MainTex ("Main Texture", 2D) = "red" {}
	}

	CGINCLUDE

	#include "UnityCG.cginc"

	Texture2D _MainTex;
	Texture2D _CameraDepthTexture;				// Built-in depth texture
	Texture2D _CameraDepthTexturePrev;			// Not built-in depth texture
	Texture2D _AoResultPrev;					// Texture2D<float2>, last frame's result. R - AO value, G - temporal weight
	Texture2D  _CameraMotionVectorsTexture;		// Built-in motion vec texture. subtract to get the uv of this fragment, in the last frame
	Texture2D _CameraGBufferTexture2;			// Built-in normal buffer. 8-bit per channel. Pretty low precision
	SamplerState  my_point_clamp_sampler;
	SamplerState  my_linear_clamp_sampler;
	Texture2D _FinalAoResult;					// Blurred in both X and Y
	//Texture2D _AoUnblendedRtTemp;
	Texture2D _AoRawResultRtTemp;				// Raw result
	Texture2D _AoXBlurredResultRtTemp;			// blurred in X

	// Define the top-right corner of the near plane, in the view space.
	// Used to reconstruct view space position of fragments
	float _FrustumCornerX;
	float _FrustumCornerY;
	float _LastFrustumCornerX;
	float _LastFrustumCornerY;

	float _StartingTemporalWeight = 0.05f;
	float _WeightStep = 0.1f;

	inline float2 uvToClipPos(float2 uv)
	{
		return 2 * (uv - 0.5);
	}

	inline float3 ReconstructViewPosFromSymmetricalProjection(float2 screenPos, float viewDepth, float2 corner)
	{
		return float3(corner * (viewDepth / _ProjectionParams.y) * screenPos.xy, -viewDepth);
	}

	// Reconstructs screen-space unit normal from screen-space position
	// The original idea is by M. McGuire
	// The invalid normal vectors at discontinutivities are a bit hard to hid with temporal reprojection
	float3 ReconstructViewNormal(float3 viewPos)
	{
		return normalize(cross(ddx(viewPos), ddy(viewPos)));
	}

	inline bool isUvOutOfBound(float2 uv)
	{
		return uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1;
	}

	inline bool isUvWithinBound(float2 uv)
	{
		return !isUvOutOfBound(uv);
	}

	ENDCG

	SubShader
	{
		Cull Off ZWrite Off ZTest Always

		// Pass 0 - Evaluation
		Pass
		{
			CGPROGRAM
			#pragma vertex vert_img
			#pragma fragment frag
			#pragma target 3.0

			
			float _BaselineDepthBias = 0.005f;
			float _DisocclusionBias = 0.005f;
			float _DisocclusionThreshold = 0.05f;
			float _NeiChangeThreshold = 0.005f;
			float _NeiChangeBias = 0.05f;
			float _WorldSpaceRadius = 1.0f;
			float _AspectRatio;
			float _ZeroDivisionGuard = 0.0005f;
			float4x4 _LastViewMatrix;
			float4x4 _InvViewMatrix;
			float4x4 _ViewMatrix;

			#define MAX_SAMPLE_COUNT (3u)
			#define	NUM_SPIRAL_TURNS (1u)
			#define UV_CLAMP_MAX (0.2f)

			// The sprial pattern used in SAO
			// Suitable for sampling across mip-map levels (not utilized here)
			inline float2 GetSampleUvOffset(uint sampleInx, float spinAngle, const uint maxSampleCount, const uint maxSpiralTurns)
			{
				const float radius = float(sampleInx + 0.5) * (1.0 / maxSampleCount);
				const float angle = radius * (maxSpiralTurns * 6.28) + spinAngle;

				return radius * float2(cos(angle), sin(angle));
			}

			// 'Hash' id.xy to a angle value
			inline float GenerateRandomAngle(uint2 fragId)
			{
				return ((4u * fragId.x ^ fragId.y + fragId.x * fragId.y) * 15u ) * (6.28f / 360.0f);
			}

			inline bool DisocclusionCheck(float2 lastUv, float projOldViewDistance, float fragOldViewDistance)
			{
							// If this fragment was out of the viewport in the last frame, the reprojection is obviously not good
				return isUvOutOfBound(lastUv) ||
							// The actual disocclusion check
					(abs(1 - (projOldViewDistance / fragOldViewDistance)) > (_DisocclusionThreshold + _DisocclusionBias));
			}

		
            float2 frag (v2f_img i) : SV_Target
            {
				// float2 fragUv is i.uv.xy;
				const uint2 fragId = i.uv.xy * _ScreenParams.xy;
				
				// the uv of this fragment in last frame
				const float2 reprojectionUv = i.uv.xy - _CameraMotionVectorsTexture.Load(int3(fragId, 0));
				// the result of the reprojection of this fragment.
				const float2 reprojectionResult = isUvOutOfBound(reprojectionUv) ? float2(0.0f, 0.0f) : _AoResultPrev.Sample(my_linear_clamp_sampler, reprojectionUv).rg;

				// EyeDistance is positive
				const float fragEyeDistance = DECODE_EYEDEPTH(_CameraDepthTexture.Sample(my_point_clamp_sampler, i.uv.xy));
				const float reprojectionEyeDistance = DECODE_EYEDEPTH(_CameraDepthTexturePrev.Sample( my_point_clamp_sampler, reprojectionUv));

				// fragViewPos.z is negative (convential z)
				const float3 fragViewPos = ReconstructViewPosFromSymmetricalProjection(uvToClipPos(i.uv.xy), fragEyeDistance, float2(_FrustumCornerX, _FrustumCornerY));
				// View-space position of the reprojection in the last frame's view
				const float3 reprojectionViewPos = ReconstructViewPosFromSymmetricalProjection(uvToClipPos(reprojectionUv), reprojectionEyeDistance, float2(_LastFrustumCornerX, _LastFrustumCornerY));
				
				const float3 fragWorldPos = mul(_InvViewMatrix, float4(fragViewPos, 1.0f)).xyz;
				// Where this fragment would be, at this frame, in the eye of the camera of the last frame
				const float3 fragLastViewPos = mul(_LastViewMatrix, float4(fragWorldPos, 1.0f)).xyz;

				// Disocclusion check
				// On Success (disoccluded) - Reject the reprojection
				// On Fail (not disoccluded) - Accept the reprojection
				float temporalWeight = DisocclusionCheck(reprojectionUv, reprojectionEyeDistance, -fragLastViewPos.z) ?
					_StartingTemporalWeight : reprojectionResult.g;

				// Using SAO's normal reconsturction. Eliminate the need of normal texture
				//const float3 fragViewNormal = ReconstructViewNormal(fragViewPos);

				// Read from the G-buffer, and get the view-space normal
				// the raw value needs to be mapped from [0, 1] to [-1, 1]
				const float3 fragViewNormal = mul(_ViewMatrix, float4(_CameraGBufferTexture2.Sample(my_point_clamp_sampler, i.uv.xy).xyz * 2 - 1, 0)).xyz;

				// Get a spin angle based on the id of the fragment.
				// Offset the angle to cover more directions in the hemisphere, based on the temporalWeight
				const float fragRandomSpinAngle = GenerateRandomAngle(fragId) + (temporalWeight - 0.5) * 6.28;

				// Project the disk onto the screen-space, clamp it to prevent sampling too far away from the fragment
				const float baseUVRadiusY = min(_WorldSpaceRadius * _ProjectionParams.y / fragEyeDistance, UV_CLAMP_MAX);
				// After the clamping, the real radius of the sphere of influence
				const float trueWorldRadius = baseUVRadiusY * fragEyeDistance / _ProjectionParams.y;
				// The real screen-space size of the disk
				const float2 trueUVRadius = float2(baseUVRadiusY / _AspectRatio, baseUVRadiusY);
				const float trueSqaureRadius = trueWorldRadius * trueWorldRadius;

				// Non-negative value
				const float adapativeDepthBias = _BaselineDepthBias * fragEyeDistance;

				float accumulatedObscurance = 0.0f;
				[unroll]
				for (uint sampleInx = 0u; sampleInx < MAX_SAMPLE_COUNT; ++sampleInx)
				{
					const float2 sampleUv = i.uv.xy + trueUVRadius * GetSampleUvOffset(sampleInx, fragRandomSpinAngle, MAX_SAMPLE_COUNT, NUM_SPIRAL_TURNS);
					const float sampleEyeDistance = DECODE_EYEDEPTH(_CameraDepthTexture.Sample(my_point_clamp_sampler, sampleUv));
					const float3 sampleViewPos = ReconstructViewPosFromSymmetricalProjection(uvToClipPos(sampleUv), sampleEyeDistance, float2(_FrustumCornerX, _FrustumCornerY));
					const float3 queryRay = sampleViewPos - fragViewPos;

					const float queryRayLengthSqr = dot(queryRay, queryRay);
					const float queryRayProjetion = dot(queryRay, fragViewNormal);

					// The four formulation in M. McGuire's SAO shaders
					//accumulatedObscurance += float(queryRayLengthSqr < trueSqaureRadius) * max((queryRayProjetion - adapativeDepthBias) / (_ZeroDivisionGuard * 100 + queryRayLengthSqr), 0.0) * trueSqaureRadius * 0.6;
					//accumulatedObscurance += pow(max(trueSqaureRadius - queryRayLengthSqr, 0.0f), 3u) * max( (queryRayProjetion - adapativeDepthBias) / (queryRayLengthSqr + _ZeroDivisionGuard), 0.0f);
					//accumulatedObscurance += 4.0 * max(1.0 - queryRayLengthSqr / trueSqaureRadius, 0.0) * max(queryRayProjetion - adapativeDepthBias, 0.0);
					//accumulatedObscurance += 2.0 * float(queryRayLengthSqr < trueSqaureRadius) * max(queryRayProjetion - adapativeDepthBias, 0.0);

					// Modified on the srcond formulation of SAO
					accumulatedObscurance += pow(max(1 - queryRayLengthSqr / trueSqaureRadius, 0.0f), 3u) * max((queryRayProjetion - adapativeDepthBias) / (queryRayLengthSqr + _ZeroDivisionGuard), 0.0f);


					// the UV of the reprojection of this sample
					const float2 sampleReprojectionUv = sampleUv - _CameraMotionVectorsTexture.Sample(my_point_clamp_sampler, sampleUv);
					// The eye distance of the reprojection of this sample
					const float sampleReprojectionEyeDistance = DECODE_EYEDEPTH(_CameraDepthTexturePrev.Sample(my_point_clamp_sampler, sampleReprojectionUv));
					// View-space pos of the reprojection
					const float3 sampleReprojectionViewPos = ReconstructViewPosFromSymmetricalProjection(uvToClipPos(sampleReprojectionUv), sampleReprojectionEyeDistance, float2(_LastFrustumCornerX, _LastFrustumCornerY));

					const float3 lastQueryRay = sampleReprojectionViewPos - reprojectionViewPos;
					// The actual nei change check
					const bool distantCheck = abs(length(lastQueryRay) - length(queryRay)) > (_NeiChangeThreshold + _NeiChangeBias);
					// additional checks  
					temporalWeight = (isUvWithinBound(sampleUv) &&			// if the sample is out of bound, only Sigmar knows what the sampling returns. 
																			// Skip the neiChange test 
						isUvWithinBound(sampleReprojectionUv) &&			// Similarily, skip the test if the reprojection is out of bound
						distantCheck &&					
						queryRayProjetion > 0) ?							// Samples in the nagative hemisphere contribute nothing to the ssao. Skip the test
						_StartingTemporalWeight :
						temporalWeight;
				}
				accumulatedObscurance /= MAX_SAMPLE_COUNT;

				float frameWeight = _WeightStep;
				
				accumulatedObscurance = (min(temporalWeight, 0.5f) * reprojectionResult.x + frameWeight * accumulatedObscurance) / (min(temporalWeight, 0.5f) + frameWeight);

				temporalWeight += _WeightStep;
				// After the temporalWeight exceeds 0.5, we want it to keep changing so that the spin angle keeps changing
				// Reset it back to 0.5 once it 'overflows' a 8-bit float
				temporalWeight = (temporalWeight > 1) ? (temporalWeight - 0.5) : temporalWeight;

				return float2(accumulatedObscurance, temporalWeight);
			}
			ENDCG
		}

		// Pass 1 - Debug
		Pass
		{
			CGPROGRAM
			#pragma vertex vert_img
			#pragma fragment frag



			float4 frag (v2f_img i) : SV_Target
			{
				const float2 result = _FinalAoResult.Sample(my_point_clamp_sampler, i.uv).rg;
				return float4(1-result.rrr, 1);
			}
			ENDCG
		}

		// Pass 2 - Blur
		Pass
		{
			CGPROGRAM
			#pragma vertex vert_img
			#pragma fragment frag

			#include "UnityCG.cginc"


			#define BLUR_KERNEL_HALF_LENGTH 1
			#if BLUR_KERNEL_HALF_LENGTH == 0
			const static float SPATIAL_WEIGHT[1] = { 1 };
			#elif BLUR_KERNEL_HALF_LENGTH == 1
			const static float SPATIAL_WEIGHT[2] = { 0.441980,		0.279010 };
			#elif BLUR_KERNEL_HALF_LENGTH == 2
			const static float SPATIAL_WEIGHT[3] = { 0.38774,		0.244770,	0.06136 };
			#elif BLUR_KERNEL_HALF_LENGTH == 3
			const static float SPATIAL_WEIGHT[4] = { 0.383103,	0.241843,	0.060626,	0.00598 };
			#elif BLUR_KERNEL_HALF_LENGTH == 4
			const static float SPATIAL_WEIGHT[5] = { 0.382928,	0.241732,	0.060598,	0.005977,	0.000229 };
			#endif

			int _StepX;
			int _StepY;

			float2 frag (v2f_img i) : SV_Target
			{

				const int2 fragId = i.uv.xy * _ScreenParams.xy;
				const float2 fragResult = _MainTex.Load(int3(fragId, 0)).rg;

				const float fragDepth = _CameraDepthTexturePrev.Load(int3(fragId, 0));
				float2 value = fragResult.rg * (SPATIAL_WEIGHT[0]);
				float weight = SPATIAL_WEIGHT[0];
				float minTemporalWeight = fragResult.g;

				[unroll]
				for (int inx = -BLUR_KERNEL_HALF_LENGTH; inx <= BLUR_KERNEL_HALF_LENGTH; ++inx)
				{
					if (inx == 0)
						continue;

					const int2 sampleId = inx * int2(_StepX, _StepY) + fragId;
					const float2 sampleResult = _MainTex.Load(int3(sampleId, 0)).rg;

					const float sampleSpatialWeight = SPATIAL_WEIGHT[abs(inx)];

					const float sampleDepth = _CameraDepthTexturePrev.Load(int3(sampleId, 0));
					const float sampleDistanceWeight = max(0.0, 1-clamp(abs(DECODE_EYEDEPTH(fragDepth) - DECODE_EYEDEPTH(sampleDepth)) / 0.1f, 0, 1));
					
					const float sampleWeight = (sampleDistanceWeight * sampleSpatialWeight);
					value += sampleWeight * sampleResult.rg;
					weight += sampleWeight;

				}
				const float2 blurredResult = value / weight;

				return float2(blurredResult.r, fragResult.g);
			}
			ENDCG
		}

		Pass 
		{
			// This shader blends the obscurance texture with ambient term of the lighting.
			// Requires High Dynmaic Range actived & Multiple Render Target supported
			// I learned this trick from MiniEngineAO (https://github.com/keijiro/MiniEngineAO). I do not claim this idea as mine.
			Blend Zero OneMinusSrcColor, Zero OneMinusSrcAlpha
			CGPROGRAM

			#pragma vertex vert
			#pragma fragment frag


			v2f_img vert(uint vid : SV_VertexID)
			{
				const float x = vid == 1u ? 2 : 0;
				const float y = vid > 1u ? 2 : 0;

				v2f_img o;
				o.pos = float4(x * 2 - 1, 1 - y * 2, 0, 1);
				o.uv = float2(x, y);
				return o;
			}

			void frag(v2f_img i, out float4 ambientBuffer : SV_Target0, out float4 lightingBuffer : SV_Target1)
			{
				const float ao = _FinalAoResult.Sample(my_point_clamp_sampler, i.uv).r;
				ambientBuffer = float4(0, 0, 0, ao);
				lightingBuffer = float4(ao, ao, ao, 0);
			}

			ENDCG
		}
    }
}
