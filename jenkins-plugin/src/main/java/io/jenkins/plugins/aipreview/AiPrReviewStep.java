package io.jenkins.plugins.aipreview;

import edu.umd.cs.findbugs.annotations.CheckForNull;
import hudson.EnvVars;
import hudson.Extension;
import hudson.FilePath;
import hudson.Launcher;
import hudson.model.Run;
import hudson.model.TaskListener;
import java.util.Set;
import org.jenkinsci.plugins.workflow.steps.Step;
import org.jenkinsci.plugins.workflow.steps.StepContext;
import org.jenkinsci.plugins.workflow.steps.StepDescriptor;
import org.jenkinsci.plugins.workflow.steps.StepExecution;
import org.kohsuke.stapler.DataBoundConstructor;
import org.kohsuke.stapler.DataBoundSetter;

/**
 * The {@code aiPrReview} pipeline step: runs the shared AI PR-review engine on
 * the current build's checkout, sandboxed by default. Every parameter is
 * optional; unset parameters fall back to the global configuration, then to
 * the engine's own defaults. The common case is a bare {@code aiPrReview()} on
 * a multibranch PR build with defaults configured globally.
 */
public class AiPrReviewStep extends Step {

    private String tool;
    private String endpoint;
    private String model;
    private Boolean sandbox;
    private String reviewImage;
    private String gate;
    private boolean postComments = true;
    private boolean dryRun;
    private boolean fetchBase = true;
    private String pr;
    private String against;
    private String anthropicApiKeyCredentialsId;
    private String openaiApiKeyCredentialsId;
    private String githubTokenCredentialsId;
    private String awsRegion;
    private String vertexProjectId;
    private String vertexRegion;
    private String anthropicBaseUrl;
    private String openaiBaseUrl;
    private String extraAllowedHosts;
    private String githubServerUrl;
    private String adjudication;
    private String adjudicationModel;
    private Integer jobs;
    private String batchBy;
    private Integer batchMinFiles;
    private Integer contextBudget;
    private String engineOverridePath;

    @DataBoundConstructor
    public AiPrReviewStep() {}

    @Override
    public StepExecution start(StepContext context) {
        return new AiPrReviewStepExecution(context, this);
    }

    // ── Getters + @DataBoundSetter for each optional parameter ────────────────

    public String getTool() {
        return tool;
    }

    @DataBoundSetter
    public void setTool(String tool) {
        this.tool = tool;
    }

    public String getEndpoint() {
        return endpoint;
    }

    @DataBoundSetter
    public void setEndpoint(String endpoint) {
        this.endpoint = endpoint;
    }

    public String getModel() {
        return model;
    }

    @DataBoundSetter
    public void setModel(String model) {
        this.model = model;
    }

    @CheckForNull
    public Boolean getSandbox() {
        return sandbox;
    }

    @DataBoundSetter
    public void setSandbox(Boolean sandbox) {
        this.sandbox = sandbox;
    }

    public String getReviewImage() {
        return reviewImage;
    }

    @DataBoundSetter
    public void setReviewImage(String reviewImage) {
        this.reviewImage = reviewImage;
    }

    public String getGate() {
        return gate;
    }

    @DataBoundSetter
    public void setGate(String gate) {
        this.gate = gate;
    }

    public boolean isPostComments() {
        return postComments;
    }

    @DataBoundSetter
    public void setPostComments(boolean postComments) {
        this.postComments = postComments;
    }

    public boolean isDryRun() {
        return dryRun;
    }

    @DataBoundSetter
    public void setDryRun(boolean dryRun) {
        this.dryRun = dryRun;
    }

    public boolean isFetchBase() {
        return fetchBase;
    }

    @DataBoundSetter
    public void setFetchBase(boolean fetchBase) {
        this.fetchBase = fetchBase;
    }

    public String getPr() {
        return pr;
    }

    @DataBoundSetter
    public void setPr(String pr) {
        this.pr = pr;
    }

    public String getAgainst() {
        return against;
    }

    @DataBoundSetter
    public void setAgainst(String against) {
        this.against = against;
    }

    public String getAnthropicApiKeyCredentialsId() {
        return anthropicApiKeyCredentialsId;
    }

    @DataBoundSetter
    public void setAnthropicApiKeyCredentialsId(String id) {
        this.anthropicApiKeyCredentialsId = id;
    }

    public String getOpenaiApiKeyCredentialsId() {
        return openaiApiKeyCredentialsId;
    }

    @DataBoundSetter
    public void setOpenaiApiKeyCredentialsId(String id) {
        this.openaiApiKeyCredentialsId = id;
    }

    public String getGithubTokenCredentialsId() {
        return githubTokenCredentialsId;
    }

    @DataBoundSetter
    public void setGithubTokenCredentialsId(String id) {
        this.githubTokenCredentialsId = id;
    }

    public String getAwsRegion() {
        return awsRegion;
    }

    @DataBoundSetter
    public void setAwsRegion(String awsRegion) {
        this.awsRegion = awsRegion;
    }

    public String getVertexProjectId() {
        return vertexProjectId;
    }

    @DataBoundSetter
    public void setVertexProjectId(String vertexProjectId) {
        this.vertexProjectId = vertexProjectId;
    }

    public String getVertexRegion() {
        return vertexRegion;
    }

    @DataBoundSetter
    public void setVertexRegion(String vertexRegion) {
        this.vertexRegion = vertexRegion;
    }

    public String getAnthropicBaseUrl() {
        return anthropicBaseUrl;
    }

    @DataBoundSetter
    public void setAnthropicBaseUrl(String anthropicBaseUrl) {
        this.anthropicBaseUrl = anthropicBaseUrl;
    }

    public String getOpenaiBaseUrl() {
        return openaiBaseUrl;
    }

    @DataBoundSetter
    public void setOpenaiBaseUrl(String openaiBaseUrl) {
        this.openaiBaseUrl = openaiBaseUrl;
    }

    public String getExtraAllowedHosts() {
        return extraAllowedHosts;
    }

    @DataBoundSetter
    public void setExtraAllowedHosts(String extraAllowedHosts) {
        this.extraAllowedHosts = extraAllowedHosts;
    }

    public String getGithubServerUrl() {
        return githubServerUrl;
    }

    @DataBoundSetter
    public void setGithubServerUrl(String githubServerUrl) {
        this.githubServerUrl = githubServerUrl;
    }

    public String getAdjudication() {
        return adjudication;
    }

    @DataBoundSetter
    public void setAdjudication(String adjudication) {
        this.adjudication = adjudication;
    }

    public String getAdjudicationModel() {
        return adjudicationModel;
    }

    @DataBoundSetter
    public void setAdjudicationModel(String adjudicationModel) {
        this.adjudicationModel = adjudicationModel;
    }

    @CheckForNull
    public Integer getJobs() {
        return jobs;
    }

    @DataBoundSetter
    public void setJobs(Integer jobs) {
        this.jobs = jobs;
    }

    public String getBatchBy() {
        return batchBy;
    }

    @DataBoundSetter
    public void setBatchBy(String batchBy) {
        this.batchBy = batchBy;
    }

    @CheckForNull
    public Integer getBatchMinFiles() {
        return batchMinFiles;
    }

    @DataBoundSetter
    public void setBatchMinFiles(Integer batchMinFiles) {
        this.batchMinFiles = batchMinFiles;
    }

    @CheckForNull
    public Integer getContextBudget() {
        return contextBudget;
    }

    @DataBoundSetter
    public void setContextBudget(Integer contextBudget) {
        this.contextBudget = contextBudget;
    }

    public String getEngineOverridePath() {
        return engineOverridePath;
    }

    @DataBoundSetter
    public void setEngineOverridePath(String engineOverridePath) {
        this.engineOverridePath = engineOverridePath;
    }

    @Extension
    public static final class DescriptorImpl extends StepDescriptor {
        @Override
        public String getFunctionName() {
            return "aiPrReview";
        }

        @Override
        public String getDisplayName() {
            return "AI-assisted security & compliance PR review";
        }

        @Override
        public Set<? extends Class<?>> getRequiredContext() {
            return Set.of(Run.class, FilePath.class, Launcher.class, TaskListener.class, EnvVars.class);
        }
    }
}
