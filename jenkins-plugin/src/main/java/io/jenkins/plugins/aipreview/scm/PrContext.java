package io.jenkins.plugins.aipreview.scm;

/** A resolved pull-request context: its number and base branch. */
public final class PrContext {
    private final String number;
    private final String baseRef;

    public PrContext(String number, String baseRef) {
        this.number = number;
        this.baseRef = baseRef;
    }

    public String getNumber() {
        return number;
    }

    public String getBaseRef() {
        return baseRef;
    }

    public boolean isComplete() {
        return number != null && !number.isEmpty() && baseRef != null && !baseRef.isEmpty();
    }
}
