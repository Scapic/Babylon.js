﻿precision mediump float;

// Constants
#define RECIPROCAL_PI2 0.15915494

uniform vec3 vEyePosition;
uniform vec3 vAmbientColor;
uniform vec4 vDiffuseColor;

// PBR CUSTOM CONTROLS
uniform vec4 vPBRLightingIntensity;
uniform vec4 vPBRShadowIntensity;
uniform vec4 vPBRCameraInfos;

uniform vec4 vPBROverloadedIntensity;
uniform vec3 vPBROverloadedAmbient;
uniform vec3 vPBROverloadedDiffuse;
uniform vec3 vPBROverloadedSpecular;
uniform vec3 vPBROverloadedEmissive;
uniform vec3 vPBROverloadedSmoothness;

// PBR CUSTOM CONSTANTS
const float kPi = 3.1415926535897932384626433832795;

// PBR HELPER METHODS
float Square(float value)
{
    return value * value;
}

float getLuminance(vec3 color)
{
    return clamp(dot(color, vec3(0.2126, 0.7152, 0.0722)), 0., 1.);
}

float convertRoughnessToAverageSlope(float roughness)
{
    // Calculate AlphaG as square of roughness; add epsilon to avoid numerical issues
    const float kMinimumVariance = 0.0005;
    float alphaG = Square(roughness) + kMinimumVariance;
    return alphaG;
}

// From Microfacet Models for Refraction through Rough Surfaces, Walter et al. 2007
float smithVisibilityG1_TrowbridgeReitzGGX(float dot, float alphaG)
{
    float tanSquared = (1.0 - dot * dot) / (dot * dot);
    return 2.0 / (1.0 + sqrt(1.0 + alphaG * alphaG * tanSquared));
}

float smithVisibilityG_TrowbridgeReitzGGX_Walter(float NdotL, float NdotV, float alphaG)
{
    return smithVisibilityG1_TrowbridgeReitzGGX(NdotL, alphaG) * smithVisibilityG1_TrowbridgeReitzGGX(NdotV, alphaG);
}

// Trowbridge-Reitz (GGX)
// Generalised Trowbridge-Reitz with gamma power=2.0
float normalDistributionFunction_TrowbridgeReitzGGX(float NdotH, float alphaG)
{
    // Note: alphaG is average slope (gradient) of the normals in slope-space.
    // It is also the (trigonometric) tangent of the median distribution value, i.e. 50% of normals have
    // a tangent (gradient) closer to the macrosurface than this slope.
    float a2 = Square(alphaG);
    float d = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (kPi * d * d);
}

vec3 fresnelSchlickGGX(float VdotH, vec3 reflectance0, vec3 reflectance90)
{
    return reflectance0 + (reflectance90 - reflectance0) * pow(clamp(1.0 - VdotH, 0., 1.), 5.0);
}

// Cook Torance Specular computation.
vec3 computeSpecularTerm(float NdotH, float NdotL, float NdotV, float VdotH, float roughness, vec3 specularColor)
{
    float alphaG = convertRoughnessToAverageSlope(roughness);
    float distribution = normalDistributionFunction_TrowbridgeReitzGGX(NdotH, alphaG);
    float visibility = smithVisibilityG_TrowbridgeReitzGGX_Walter(NdotL, NdotV, alphaG);
    visibility /= (4.0 * NdotL * NdotV); // Cook Torance Denominator  integated in viibility to avoid issues when visibility function changes.

    vec3 fresnel = fresnelSchlickGGX(VdotH, specularColor, vec3(1., 1., 1.));

    float specTerm = max(0., visibility * distribution) * NdotL;
    return fresnel * specTerm;
}

float computeDiffuseTerm(float NdotL, float NdotV, float VdotH, float roughness)
{
    // Diffuse fresnel falloff as per Disney principled BRDF, and in the spirit of
    // of general coupled diffuse/specular models e.g. Ashikhmin Shirley.
    float diffuseFresnelNV = pow(clamp(1.0 - NdotL, 0.000001, 1.), 5.0);
    float diffuseFresnelNL = pow(clamp(1.0 - NdotV, 0.000001, 1.), 5.0);
    float diffuseFresnel90 = 0.5 + 2.0 * VdotH * VdotH * roughness;
    float diffuseFresnelTerm =
        (1.0 + (diffuseFresnel90 - 1.0) * diffuseFresnelNL) *
        (1.0 + (diffuseFresnel90 - 1.0) * diffuseFresnelNV);

    return diffuseFresnelTerm * NdotL;
}

float computeDefaultGlossiness(float glossiness, vec3 specularColor)
{
    if (glossiness == 0.)
    {
        float kSpecularNoAlphaWorkflow_SmoothnessMax = 0.95;

        float specularLuminance = getLuminance(specularColor);
        float specularLuma = sqrt(specularLuminance);
        glossiness = specularLuma * kSpecularNoAlphaWorkflow_SmoothnessMax;
    }
    return glossiness;
}

vec3 toLinearSpace(vec3 color)
{
    return vec3(pow(color.r, 2.2), pow(color.g, 2.2), pow(color.b, 2.2));
}

vec3 toGammaSpace(vec3 color)
{
    return vec3(pow(color.r, 1.0 / 2.2), pow(color.g, 1.0 / 2.2), pow(color.b, 1.0 / 2.2));
}

vec3 toneMaps(vec3 color)
{
    color = max(color, 0.0);

    // TONE MAPPING / EXPOSURE
    color.rgb = color.rgb * vPBRCameraInfos.x;

    float tuning = 1.5; // TODO: sync up so e.g. 18% greys are matched to exposure appropriately
    vec3 tonemapped = 1.0 - exp2(-color.rgb * tuning); // simple local photographic tonemapper
    color.rgb = mix(color.rgb, tonemapped, 1.0);
    return color;
}

vec4 contrasts(vec4 color)
{
    color = clamp(color, 0.0, 1.0);

    vec3 resultHighContrast = color.rgb * color.rgb * (3.0 - 2.0 * color.rgb);
    float contrast = vPBRCameraInfos.y;
    if (contrast < 1.0)
    {
        // Decrease contrast: interpolate towards zero-contrast image (flat grey)
        color.rgb = mix(vec3(0.5, 0.5, 0.5), color.rgb, contrast);
    }
    else
    {
        // Increase contrast: apply simple shoulder-toe high contrast curve
        color.rgb = mix(color.rgb, resultHighContrast, contrast - 1.0);
    }

    return color;
}
// END PBR HELPER METHODS

#ifdef SPECULARTERM
uniform vec4 vSpecularColor;
#endif
uniform vec3 vEmissiveColor;

// Input
varying vec3 vPositionW;

#ifdef NORMAL
varying vec3 vNormalW;
#endif

#ifdef VERTEXCOLOR
varying vec4 vColor;
#endif

// Lights
#ifdef LIGHT0
uniform vec4 vLightData0;
uniform vec4 vLightDiffuse0;
#ifdef SPECULARTERM
uniform vec3 vLightSpecular0;
#endif
#ifdef SHADOW0
#if defined(SPOTLIGHT0) || defined(DIRLIGHT0)
varying vec4 vPositionFromLight0;
uniform sampler2D shadowSampler0;
#else
uniform samplerCube shadowSampler0;
#endif
uniform vec3 shadowsInfo0;
#endif
#ifdef SPOTLIGHT0
uniform vec4 vLightDirection0;
#endif
#ifdef HEMILIGHT0
uniform vec3 vLightGround0;
#endif
#endif

#ifdef LIGHT1
uniform vec4 vLightData1;
uniform vec4 vLightDiffuse1;
#ifdef SPECULARTERM
uniform vec3 vLightSpecular1;
#endif
#ifdef SHADOW1
#if defined(SPOTLIGHT1) || defined(DIRLIGHT1)
varying vec4 vPositionFromLight1;
uniform sampler2D shadowSampler1;
#else
uniform samplerCube shadowSampler1;
#endif
uniform vec3 shadowsInfo1;
#endif
#ifdef SPOTLIGHT1
uniform vec4 vLightDirection1;
#endif
#ifdef HEMILIGHT1
uniform vec3 vLightGround1;
#endif
#endif

#ifdef LIGHT2
uniform vec4 vLightData2;
uniform vec4 vLightDiffuse2;
#ifdef SPECULARTERM
uniform vec3 vLightSpecular2;
#endif
#ifdef SHADOW2
#if defined(SPOTLIGHT2) || defined(DIRLIGHT2)
varying vec4 vPositionFromLight2;
uniform sampler2D shadowSampler2;
#else
uniform samplerCube shadowSampler2;
#endif
uniform vec3 shadowsInfo2;
#endif
#ifdef SPOTLIGHT2
uniform vec4 vLightDirection2;
#endif
#ifdef HEMILIGHT2
uniform vec3 vLightGround2;
#endif
#endif

#ifdef LIGHT3
uniform vec4 vLightData3;
uniform vec4 vLightDiffuse3;
#ifdef SPECULARTERM
uniform vec3 vLightSpecular3;
#endif
#ifdef SHADOW3
#if defined(SPOTLIGHT3) || defined(DIRLIGHT3)
varying vec4 vPositionFromLight3;
uniform sampler2D shadowSampler3;
#else
uniform samplerCube shadowSampler3;
#endif
uniform vec3 shadowsInfo3;
#endif
#ifdef SPOTLIGHT3
uniform vec4 vLightDirection3;
#endif
#ifdef HEMILIGHT3
uniform vec3 vLightGround3;
#endif
#endif

// Samplers
#ifdef DIFFUSE
varying vec2 vDiffuseUV;
uniform sampler2D diffuseSampler;
uniform vec2 vDiffuseInfos;
#endif

#ifdef AMBIENT
varying vec2 vAmbientUV;
uniform sampler2D ambientSampler;
uniform vec2 vAmbientInfos;
#endif

#ifdef OPACITY	
varying vec2 vOpacityUV;
uniform sampler2D opacitySampler;
uniform vec2 vOpacityInfos;
#endif

#ifdef EMISSIVE
varying vec2 vEmissiveUV;
uniform vec2 vEmissiveInfos;
uniform sampler2D emissiveSampler;
#endif

#ifdef LIGHTMAP
varying vec2 vLightmapUV;
uniform vec2 vLightmapInfos;
uniform sampler2D lightmapSampler;
#endif

#if defined(SPECULAR) && defined(SPECULARTERM)
varying vec2 vSpecularUV;
uniform vec2 vSpecularInfos;
uniform sampler2D specularSampler;
#endif

#ifdef CLIPPLANE
varying float fClipDistance;
#endif

// Light Computing
struct lightingInfo
{
    vec3 diffuse;
#ifdef SPECULARTERM
    vec3 specular;
#endif
};

lightingInfo computeLighting(vec3 viewDirectionW, vec3 vNormal, vec4 lightData, vec3 diffuseColor, vec3 specularColor, float range, float roughness, float NdotV) {
    lightingInfo result;

    vec3 lightVectorW;
    float attenuation = 1.0;
    if (lightData.w == 0.)
    {
        vec3 direction = lightData.xyz - vPositionW;

        attenuation = max(0., 1.0 - length(direction) / range);
        lightVectorW = normalize(direction);
    }
    else
    {
        lightVectorW = normalize(-lightData.xyz);
    }

    // diffuse
    vec3 H = normalize(viewDirectionW + lightVectorW);
    float NdotL = max(0.00000000001, dot(vNormal, lightVectorW));
    float VdotH = clamp(0.00000000001, 1.0, dot(viewDirectionW, H));

    float diffuseTerm = computeDiffuseTerm(NdotL, NdotV, VdotH, roughness);
    result.diffuse = diffuseTerm * diffuseColor * attenuation;

#ifdef SPECULARTERM
    // Specular
    float NdotH = max(0.00000000001, dot(vNormal, H));

    vec3 specTerm = computeSpecularTerm(NdotH, NdotL, NdotV, VdotH, roughness, specularColor);
    result.specular = specTerm * specularColor * attenuation;
#endif

    return result;
}

lightingInfo computeSpotLighting(vec3 viewDirectionW, vec3 vNormal, vec4 lightData, vec4 lightDirection, vec3 diffuseColor, vec3 specularColor, float range, float roughness, float NdotV) {
    lightingInfo result;

    vec3 direction = lightData.xyz - vPositionW;
    vec3 lightVectorW = normalize(direction);
    float attenuation = max(0., 1.0 - length(direction) / range);

    // diffuse
    float cosAngle = max(0.0000001, dot(-lightDirection.xyz, lightVectorW));
    float spotAtten = 0.0;

    if (cosAngle >= lightDirection.w)
    {
        cosAngle = max(0., pow(cosAngle, lightData.w));
        spotAtten = clamp((cosAngle - lightDirection.w) / (1. - cosAngle), 0.0, 1.0);

        // Diffuse
        vec3 H = normalize(viewDirectionW - lightDirection.xyz);
        float NdotL = max(0.00000000001, dot(vNormal, -lightDirection.xyz));
        float VdotH = clamp(dot(viewDirectionW, H), 0.00000000001, 1.0);

        float diffuseTerm = computeDiffuseTerm(NdotL, NdotV, VdotH, roughness);
        result.diffuse = diffuseTerm * diffuseColor * attenuation * spotAtten;

#ifdef SPECULARTERM
        // Specular
        float NdotH = max(0.00000000001, dot(vNormal, H));

        vec3 specTerm = computeSpecularTerm(NdotH, NdotL, NdotV, VdotH, roughness, specularColor);
        result.specular = specTerm * specularColor * attenuation * spotAtten;
#endif

        return result;
    }

    result.diffuse = vec3(0.);
#ifdef SPECULARTERM
    result.specular = vec3(0.);
#endif

    return result;
}

lightingInfo computeHemisphericLighting(vec3 viewDirectionW, vec3 vNormal, vec4 lightData, vec3 diffuseColor, vec3 specularColor, vec3 groundColor, float roughness, float NdotV) {
    lightingInfo result;

    vec3 lightVectorW = normalize(lightData.xyz);

    // Diffuse
    float ndl = dot(vNormal, lightData.xyz) * 0.5 + 0.5;
    result.diffuse = mix(groundColor, diffuseColor, ndl);

#ifdef SPECULARTERM
    // Specular
    vec3 H = normalize(viewDirectionW + lightVectorW);
    float NdotH = max(0.00000000001, dot(vNormal, H));
    float NdotL = max(0.00000000001, ndl);
    float VdotH = clamp(0.00000000001, 1.0, dot(viewDirectionW, H));

    vec3 specTerm = computeSpecularTerm(NdotH, NdotL, NdotV, VdotH, roughness, specularColor);
    result.specular = specTerm * specularColor;
#endif

    return result;
}

void main(void) {
    // Clip plane
#ifdef CLIPPLANE
    if (fClipDistance > 0.0)
        discard;
#endif

    vec3 viewDirectionW = normalize(vEyePosition - vPositionW);

    // Base color
    vec4 baseColor = vec4(1., 1., 1., 1.);
    vec3 diffuseColor = vDiffuseColor.rgb;
    
    // Alpha
    float alpha = vDiffuseColor.a;

#ifdef DIFFUSE
    baseColor = texture2D(diffuseSampler, vDiffuseUV);
    baseColor = vec4(toLinearSpace(baseColor.rgb), baseColor.a);

#ifdef ALPHATEST
    if (baseColor.a < 0.4)
        discard;
#endif

#ifdef ALPHAFROMDIFFUSE
    alpha *= baseColor.a;
#endif

    baseColor.rgb *= vDiffuseInfos.y;
#endif

    baseColor.rgb = mix(baseColor.rgb, vPBROverloadedDiffuse, vPBROverloadedIntensity.y);

#ifdef VERTEXCOLOR
    baseColor.rgb *= vColor.rgb;
#endif

    // Bump
#ifdef NORMAL
    vec3 normalW = normalize(vNormalW);
#else
    vec3 normalW = vec3(1.0, 1.0, 1.0);
#endif

    // Ambient color
    vec3 baseAmbientColor = vec3(1., 1., 1.);

#ifdef AMBIENT
    baseAmbientColor = texture2D(ambientSampler, vAmbientUV).rgb * vAmbientInfos.y;
    baseAmbientColor.rgb = mix(baseAmbientColor.rgb, vPBROverloadedAmbient, vPBROverloadedIntensity.x);
#endif

    // Specular map
#ifdef SPECULARTERM
    float glossiness = vSpecularColor.a;
    vec3 specularColor = vSpecularColor.rgb;

#ifdef SPECULAR
    vec4 specularMapColor = texture2D(specularSampler, vSpecularUV);
    specularColor *= toLinearSpace(specularMapColor.rgb);
#ifdef GLOSSINESS
    glossiness = specularMapColor.a;
#endif
#endif
    specularColor.rgb = mix(specularColor.rgb, vPBROverloadedSpecular, vPBROverloadedIntensity.z);
    glossiness = computeDefaultGlossiness(glossiness, specularColor);
    glossiness = mix(glossiness, vPBROverloadedSmoothness.x, vPBROverloadedSmoothness.y);
    #else
    float glossiness = 0.;
    glossiness = mix(glossiness, vPBROverloadedSmoothness.x, vPBROverloadedSmoothness.y);
    vec3 specularColor = vec3(0., 0., 0);
    specularColor.rgb = mix(specularColor.rgb, vPBROverloadedSpecular, vPBROverloadedIntensity.z);
#endif

    // Apply Energy Conservation.
    float reflectance = max(max(specularColor.r, specularColor.g), specularColor.b);
    baseColor.rgb = (1. - reflectance) * baseColor.rgb;

    // Compute Specular Fresnel + Reflectance.
    float NdotV = max(0.00000000001, dot(normalW, viewDirectionW));

    // Adapt glossiness.
    glossiness = clamp(glossiness, 0., 1.) * 0.98;

    // Call rough to not conflict with previous one.
    float rough = clamp(1. - glossiness, 0.000001, 1.0);

    // Lighting
    vec3 diffuseBase = vec3(0., 0., 0.);
    vec3 shadowedOnly = vPBROverloadedDiffuse;
#ifdef SPECULARTERM
    vec3 specularBase = vec3(0., 0., 0.);
#endif
    float shadow = 1.;

#ifdef LIGHT0
#ifndef SPECULARTERM
    vec3 vLightSpecular0 = vec3(0.0);
#endif
#ifdef SPOTLIGHT0
    lightingInfo info = computeSpotLighting(viewDirectionW, normalW, vLightData0, vLightDirection0, vLightDiffuse0.rgb, vLightSpecular0, vLightDiffuse0.a, rough, NdotV);
#endif
#ifdef HEMILIGHT0
    lightingInfo info = computeHemisphericLighting(viewDirectionW, normalW, vLightData0, vLightDiffuse0.rgb, vLightSpecular0, vLightGround0, rough, NdotV);
#endif
#if defined(POINTLIGHT0) || defined(DIRLIGHT0)
    lightingInfo info = computeLighting(viewDirectionW, normalW, vLightData0, vLightDiffuse0.rgb, vLightSpecular0, vLightDiffuse0.a, rough, NdotV);
#endif

    shadow = 1.;
    diffuseBase += info.diffuse * shadow;
    shadowedOnly *= shadow;

#ifdef SPECULARTERM
    specularBase += info.specular * shadow;
#endif
#endif

#ifdef LIGHT1
#ifndef SPECULARTERM
    vec3 vLightSpecular1 = vec3(0.0);
#endif
#ifdef SPOTLIGHT1
    info = computeSpotLighting(viewDirectionW, normalW, vLightData1, vLightDirection1, vLightDiffuse1.rgb, vLightSpecular1, vLightDiffuse1.a, rough, NdotV);
#endif
#ifdef HEMILIGHT1
    info = computeHemisphericLighting(viewDirectionW, normalW, vLightData1, vLightDiffuse1.rgb, vLightSpecular1, vLightGround1, rough, NdotV);
#endif
#if defined(POINTLIGHT1) || defined(DIRLIGHT1)
    info = computeLighting(viewDirectionW, normalW, vLightData1, vLightDiffuse1.rgb, vLightSpecular1, vLightDiffuse1.a, rough, NdotV);
#endif

    shadow = 1.;
    diffuseBase += info.diffuse * shadow;
    shadowedOnly *= shadow;

#ifdef SPECULARTERM
    specularBase += info.specular * shadow;
#endif
#endif

#ifdef LIGHT2
#ifndef SPECULARTERM
    vec3 vLightSpecular2 = vec3(0.0);
#endif
#ifdef SPOTLIGHT2
    info = computeSpotLighting(viewDirectionW, normalW, vLightData2, vLightDirection2, vLightDiffuse2.rgb, vLightSpecular2, vLightDiffuse2.a, rough, NdotV);
#endif
#ifdef HEMILIGHT2
    info = computeHemisphericLighting(viewDirectionW, normalW, vLightData2, vLightDiffuse2.rgb, vLightSpecular2, vLightGround2, rough, NdotV);
#endif
#if defined(POINTLIGHT2) || defined(DIRLIGHT2)
    info = computeLighting(viewDirectionW, normalW, vLightData2, vLightDiffuse2.rgb, vLightSpecular2, vLightDiffuse2.a, rough, NdotV);
#endif

    shadow = 1.;
    diffuseBase += info.diffuse * shadow;
    shadowedOnly *= shadow;

#ifdef SPECULARTERM
    specularBase += info.specular * shadow;
#endif
#endif

#ifdef LIGHT3
#ifndef SPECULARTERM
    vec3 vLightSpecular3 = vec3(0.0);
#endif
#ifdef SPOTLIGHT3
    info = computeSpotLighting(viewDirectionW, normalW, vLightData3, vLightDirection3, vLightDiffuse3.rgb, vLightSpecular3, vLightDiffuse3.a, rough, NdotV);
#endif
#ifdef HEMILIGHT3
    info = computeHemisphericLighting(viewDirectionW, normalW, vLightData3, vLightDiffuse3.rgb, vLightSpecular3, vLightGround3, rough, NdotV);
#endif
#if defined(POINTLIGHT3) || defined(DIRLIGHT3)
    info = computeLighting(viewDirectionW, normalW, vLightData3, vLightDiffuse3.rgb, vLightSpecular3, vLightDiffuse3.a, rough, NdotV);
#endif

    shadow = 1.;
    diffuseBase += info.diffuse * shadow;
    shadowedOnly *= shadow;

#ifdef SPECULARTERM
    specularBase += info.specular * shadow;
#endif
#endif

    // Reflection
    vec3 reflectionColor = vec3(0., 0., 0.);

#ifdef OPACITY
    vec4 opacityMap = texture2D(opacitySampler, vOpacityUV);

#ifdef OPACITYRGB
    opacityMap.rgb = opacityMap.rgb * vec3(0.3, 0.59, 0.11);
    alpha *= (opacityMap.x + opacityMap.y + opacityMap.z)* vOpacityInfos.y;
#else
    alpha *= opacityMap.a * vOpacityInfos.y;
#endif

#endif

#ifdef VERTEXALPHA
    alpha *= vColor.a;
#endif

    // Emissive
    vec3 emissiveColor = vEmissiveColor;
#ifdef EMISSIVE
    vec3 emissiveColorTex = texture2D(emissiveSampler, vEmissiveUV).rgb;
    emissiveColor = toLinearSpace(emissiveColorTex.rgb) * emissiveColor * vEmissiveInfos.y;
    emissiveColor = mix(emissiveColor, vPBROverloadedEmissive, vPBROverloadedIntensity.w);
#endif

    // Composition
#ifdef EMISSIVEASILLUMINATION
    vec3 finalDiffuse = max(diffuseBase * diffuseColor + vAmbientColor, 0.0) * baseColor.rgb;
#else
    #ifdef LINKEMISSIVEWITHDIFFUSE
        vec3 finalDiffuse = clamp((diffuseBase + emissiveColor) * diffuseColor + vAmbientColor, 0.0, 1.0) * baseColor.rgb;
    #else
        vec3 finalDiffuse = clamp(diffuseBase * diffuseColor + emissiveColor + vAmbientColor, 0.0, 1.0) * baseColor.rgb;
    #endif
#endif

#ifdef SPECULARTERM
    vec3 finalSpecular = specularBase * specularColor;
#else
    vec3 finalSpecular = vec3(0.0);
#endif

#ifdef SPECULAROVERALPHA
    alpha = clamp(alpha + dot(finalSpecular, vec3(0.3, 0.59, 0.11)), 0., 1.);
#endif

    // Composition
#ifdef EMISSIVEASILLUMINATION
    vec4 color = vec4(finalDiffuse * baseAmbientColor * vPBRLightingIntensity.x + finalSpecular * vPBRLightingIntensity.x + reflectionColor * vPBRLightingIntensity.z + emissiveColor * vPBRLightingIntensity.y, alpha);
#else
    vec4 color = vec4(finalDiffuse * baseAmbientColor + finalSpecular + reflectionColor, alpha);
#endif

    color = max(color, 0.0);

    color.rgb = toneMaps(color.rgb);
    color.rgb = toGammaSpace(color.rgb);
    color = contrasts(color);

    color.rgb = mix(color.rgb, shadowedOnly, (1.0 - vPBRShadowIntensity.y));

    gl_FragColor = color;
}
