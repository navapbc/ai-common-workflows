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
 * The {@code aiSecurityComplianceReview} pipeline step: runs the shared AI
 * security &amp; compliance review engine on the current build's checkout. Every
 * parameter is optional; unset parameters fall back to the global configuration,
 * then to the engine's own defaults. The common case is a bare
 * {@code aiSecurityComplianceReview()} on a multibranch PR build with defaults
 * configured globally.
 */
public class AiPrReviewStep extends Step {

    private String tool;
    private String endpoint;
    private String model;
    private String profile;
    private String gate;
    private boolean postComments = true;
    private boolean postWhenClean;
    private Integer maxComments;
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
    private String copilotProviderBaseUrl;
    private String copilotProviderType;
    private String copilotProviderApiKeyCredentialsId;
    private String copilotModel;
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

    public String getProfile() {
        return profile;
    }

    @DataBoundSetter
    public void setProfile(String profile) {
        this.profile = profile;
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

    public boolean isPostWhenClean() {
        return postWhenClean;
    }

    /**
     * Post a review when the diff produced no findings. Defaults to false: the
     * build result already reports a clean run, so acknowledging every clean PR
     * is a notification whose entire content is that nothing happened. Turn it
     * on where the approval on the PR itself is the artifact — evidence per PR
     * that outlives a build record.
     *
     * <p>Findings always post regardless, and so does a REQUEST_CHANGES review
     * that carries none.
     */
    @DataBoundSetter
    public void setPostWhenClean(boolean postWhenClean) {
        this.postWhenClean = postWhenClean;
    }

    public Integer getMaxComments() {
        return maxComments;
    }

    /**
     * Limit on inline comments per review. Null leaves the engine default (50)
     * in place; 0 means no limit. Over the limit the highest-severity findings
     * stay inline and the rest are listed in the review body — nothing is
     * dropped, and the gate still accounts for every finding.
     */
    @DataBoundSetter
    public void setMaxComments(Integer maxComments) {
        this.maxComments = maxComments;
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

    public String getCopilotProviderBaseUrl() {
        return copilotProviderBaseUrl;
    }

    @DataBoundSetter
    public void setCopilotProviderBaseUrl(String copilotProviderBaseUrl) {
        this.copilotProviderBaseUrl = copilotProviderBaseUrl;
    }

    public String getCopilotProviderType() {
        return copilotProviderType;
    }

    @DataBoundSetter
    public void setCopilotProviderType(String copilotProviderType) {
        this.copilotProviderType = copilotProviderType;
    }

    public String getCopilotProviderApiKeyCredentialsId() {
        return copilotProviderApiKeyCredentialsId;
    }

    @DataBoundSetter
    public void setCopilotProviderApiKeyCredentialsId(String id) {
        this.copilotProviderApiKeyCredentialsId = id;
    }

    public String getCopilotModel() {
        return copilotModel;
    }

    @DataBoundSetter
    public void setCopilotModel(String copilotModel) {
        this.copilotModel = copilotModel;
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
            return "aiSecurityComplianceReview";
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
