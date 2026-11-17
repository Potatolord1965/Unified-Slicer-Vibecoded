#pragma once

#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>

namespace Slic3r { namespace GUI {

// One background thread for a view that polls every few seconds, instead of a new thread per poll.
// post() hands it the next job; a job that is still waiting is replaced, so slow replies never
// pile up. The owner may be destroyed while a job runs: the thread holds its own state, finishes
// that job and exits, and the job must check its own "alive" flag before touching the owner.
class PollWorker
{
public:
    PollWorker() : m_state(std::make_shared<State>())
    {
        std::thread([state = m_state] {
            std::unique_lock<std::mutex> lock(state->mutex);
            for (;;) {
                state->cv.wait(lock, [&state] { return state->stop || state->job; });
                if (state->stop)
                    return;
                std::function<void()> job = std::move(state->job);
                state->job                = nullptr;
                lock.unlock();
                job();
                lock.lock();
            }
        }).detach();
    }
    ~PollWorker()
    {
        {
            std::lock_guard<std::mutex> lock(m_state->mutex);
            m_state->stop = true;
            m_state->job  = nullptr;
        }
        m_state->cv.notify_one();
    }
    PollWorker(const PollWorker&)            = delete;
    PollWorker& operator=(const PollWorker&) = delete;

    void post(std::function<void()> job)
    {
        {
            std::lock_guard<std::mutex> lock(m_state->mutex);
            m_state->job = std::move(job);
        }
        m_state->cv.notify_one();
    }

private:
    struct State
    {
        std::mutex              mutex;
        std::condition_variable cv;
        std::function<void()>   job;
        bool                    stop{false};
    };
    std::shared_ptr<State> m_state;
};

}} // namespace Slic3r::GUI
