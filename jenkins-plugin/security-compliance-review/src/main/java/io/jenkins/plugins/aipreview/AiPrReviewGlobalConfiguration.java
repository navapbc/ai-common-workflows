package io.jenkins.plugins.aipreview;

import hudson.Extension;
import jenkins.model.GlobalConfiguration;
import org.kohsuke.stapler.DataBoundSetter;
import org.jenkinsci.Symbol;

/**
 * Org-wide defaults for the {@code aiSecurityComplianceReview} step, set under
 * Manage Jenkins → System. Every field is optional; a value set here is used
 * whenever the corresponding step parameter is left unset, so the common
 * Jenkinsfile case can be a bare {@code aiSecurityComplianceReview()}.
 *
 * <p>JCasC-ready via {@code @Symbol("aiSecurityComplianceReview")}.
 */
@Extension
@Symbol("aiSecurityComplianceReview")
public class AiPrReviewGlobalConfiguration extends GlobalConfiguration {

    private String tool;
    private String endpoint;
    private String model;
    private String profile;
    private String gate;
    private String awsRegion;
    private String vertexProjectId;
    private String vertexRegion;
    private String anthropicBaseUrl;
    private String openaiBaseUrl;
    private String githubServerUrl;
    private String anthropicApiKeyCredentialsId;
    private String openaiApiKeyCredentialsId;
    private String githubTokenCredentialsId;
    private String adjudication;
    private String adjudicationModel;

    public AiPrReviewGlobalConfiguration() {
        load();
    }

    public static AiPrReviewGlobalConfiguration get() {
        return GlobalConfiguration.all().get(AiPrReviewGlobalConfiguration.class);
    }

    public String getTool() {
        return tool;
    }

    @DataBoundSetter
    public void setTool(String tool) {
        this.tool = tool;
        save();
    }

    public String getEndpoint() {
        return endpoint;
    }

    @DataBoundSetter
    public void setEndpoint(String endpoint) {
        this.endpoint = endpoint;
        save();
    }

    public String getModel() {
        return model;
    }

    @DataBoundSetter
    public void setModel(String model) {
        this.model = model;
        save();
    }

    public String getProfile() {
        return profile;
    }

    @DataBoundSetter
    public void setProfile(String profile) {
        this.profile = profile;
        save();
    }

    public String getGate() {
        return gate;
    }

    @DataBoundSetter
    public void setGate(String gate) {
        this.gate = gate;
        save();
    }

    public String getAwsRegion() {
        return awsRegion;
    }

    @DataBoundSetter
    public void setAwsRegion(String awsRegion) {
        this.awsRegion = awsRegion;
        save();
    }

    public String getVertexProjectId() {
        return vertexProjectId;
    }

    @DataBoundSetter
    public void setVertexProjectId(String vertexProjectId) {
        this.vertexProjectId = vertexProjectId;
        save();
    }

    public String getVertexRegion() {
        return vertexRegion;
    }

    @DataBoundSetter
    public void setVertexRegion(String vertexRegion) {
        this.vertexRegion = vertexRegion;
        save();
    }

    public String getAnthropicBaseUrl() {
        return anthropicBaseUrl;
    }

    @DataBoundSetter
    public void setAnthropicBaseUrl(String anthropicBaseUrl) {
        this.anthropicBaseUrl = anthropicBaseUrl;
        save();
    }

    public String getOpenaiBaseUrl() {
        return openaiBaseUrl;
    }

    @DataBoundSetter
    public void setOpenaiBaseUrl(String openaiBaseUrl) {
        this.openaiBaseUrl = openaiBaseUrl;
        save();
    }

    public String getGithubServerUrl() {
        return githubServerUrl;
    }

    @DataBoundSetter
    public void setGithubServerUrl(String githubServerUrl) {
        this.githubServerUrl = githubServerUrl;
        save();
    }

    public String getAnthropicApiKeyCredentialsId() {
        return anthropicApiKeyCredentialsId;
    }

    @DataBoundSetter
    public void setAnthropicApiKeyCredentialsId(String id) {
        this.anthropicApiKeyCredentialsId = id;
        save();
    }

    public String getOpenaiApiKeyCredentialsId() {
        return openaiApiKeyCredentialsId;
    }

    @DataBoundSetter
    public void setOpenaiApiKeyCredentialsId(String id) {
        this.openaiApiKeyCredentialsId = id;
        save();
    }

    public String getGithubTokenCredentialsId() {
        return githubTokenCredentialsId;
    }

    @DataBoundSetter
    public void setGithubTokenCredentialsId(String id) {
        this.githubTokenCredentialsId = id;
        save();
    }

    public String getAdjudication() {
        return adjudication;
    }

    @DataBoundSetter
    public void setAdjudication(String adjudication) {
        this.adjudication = adjudication;
        save();
    }

    public String getAdjudicationModel() {
        return adjudicationModel;
    }

    @DataBoundSetter
    public void setAdjudicationModel(String adjudicationModel) {
        this.adjudicationModel = adjudicationModel;
        save();
    }
}
